import Darwin
import Foundation

struct DirectoryChangeBatch: Equatable, Sendable {
    let paths: [String]
    let mustRescan: Bool
    let directoryPaths: Set<String>
    let filePaths: Set<String>

    init(paths: [String], mustRescan: Bool, directoryPaths: Set<String> = [], filePaths: Set<String> = []) {
        self.paths = paths
        self.mustRescan = mustRescan
        self.directoryPaths = directoryPaths
        self.filePaths = filePaths
    }
}

/// Suppresses only recent, exact post-write states. Ambiguous directory events always request a scan.
final class LocalFileChangeSuppression: @unchecked Sendable {
    static let shared = LocalFileChangeSuppression()
    private let lock = NSLock()
    private let lifetime: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private var writes: [String: RecordedWrite] = [:]

    init(lifetime: TimeInterval = 10, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.lifetime = max(0, lifetime); self.now = now
    }

    /// Call off the foreground after successful local writes and the matching library update.
    func recordWrites(urls: [URL]) {
        let timestamp = now()
        let records: [(String, RecordedWrite)] = urls.filter(\.isFileURL).compactMap { url in
            let file = url.standardizedFileURL
            guard let fingerprint = FileState(path: file.path), fingerprint.isRegularFile,
                  let parent = FileState(path: file.deletingLastPathComponent().path) else { return nil }
            return (file.path, RecordedWrite(file: fingerprint, parent: parent, timestamp: timestamp))
        }
        lock.withLock {
            writes = writes.filter { timestamp - $0.value.timestamp < lifetime }
            for (path, record) in records { writes[path] = record }
            if writes.count > 4096 {
                let excess = writes.sorted { $0.value.timestamp < $1.value.timestamp }.prefix(writes.count - 4096)
                for (path, _) in excess { writes.removeValue(forKey: path) }
            }
        }
    }

    /// FSEvents invokes this on its utility queue; filesystem attribute reads never hold the shared lock.
    func shouldRescan(_ batch: DirectoryChangeBatch) -> Bool {
        guard !batch.mustRescan, !batch.paths.isEmpty else { return true }
        let timestamp = now()
        let recent = lock.withLock {
            writes = writes.filter { timestamp - $0.value.timestamp < lifetime }
            return writes
        }
        guard !recent.isEmpty else { return true }
        for rawPath in Set(batch.paths) {
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            if let recorded = recent[url.path], let current = FileState(path: url.path), current == recorded.file { continue }
            // The verified TagLib writer creates a hidden sibling named .macarok-UUID.ext, then
            // atomically replaces its target. Ignore only that absent staging path, in an unchanged
            // recorded parent with at least one still-matching target. Directory-only events remain ambiguous.
            if isCompletedTagLibStagingFile(url, recent: recent) { continue }
            return true
        }
        return false
    }

    private func isCompletedTagLibStagingFile(_ url: URL, recent: [String: RecordedWrite]) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix(".macarok-"), UUID(uuidString: String(stem.dropFirst(".macarok-".count))) != nil,
              FileState(path: url.path) == nil else { return false }
        let parentPath = url.deletingLastPathComponent().path
        guard let parent = FileState(path: parentPath) else { return false }
        return recent.contains { path, recorded in
            let target = URL(fileURLWithPath: path)
            return target.deletingLastPathComponent().path == parentPath && target.pathExtension == url.pathExtension &&
                recorded.parent == parent && FileState(path: path) == recorded.file
        }
    }

    private struct RecordedWrite {
        let file: FileState
        let parent: FileState
        let timestamp: TimeInterval
    }

    private struct FileState: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let mode: UInt16
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        var isRegularFile: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
        init?(path: String) {
            var info = stat()
            guard path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return nil }
            device = info.st_dev; inode = info.st_ino; size = info.st_size; mode = info.st_mode
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }
}
