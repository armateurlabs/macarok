import Foundation

public struct PodcastDownload: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sourceID: String
    public let trackID: String
    public let title: String
    public let filename: String
    public let byteCount: Int64
    public let downloadedAt: Date
}

public enum PodcastDownloadError: LocalizedError {
    case alreadyDownloading
    public var errorDescription: String? { "This episode is already downloading. Wait for the current transfer to finish or cancel." }
}

/// Explicit downloads are durable user files, separate from the disposable streaming buffer.
public actor PodcastDownloadStore {
    public let directory: URL
    private var records: [String: PodcastDownload] = [:]
    private var loaded = false
    private var activeKeys: Set<String> = []

    public init(directory: URL) { self.directory = directory.standardizedFileURL }
    public nonisolated static func key(sourceID: String, trackID: String) -> String { StableID.make(sourceID, trackID) }
    private var manifest: URL { directory.appendingPathComponent("downloads.json") }

    public func list() throws -> [PodcastDownload] {
        try load()
        let valid = records.filter { file(for: $0.value) != nil }
        if valid.count != records.count { records = valid; try persist() }
        return records.values.sorted { $0.downloadedAt > $1.downloadedAt }
    }

    public func file(for download: PodcastDownload) -> URL? {
        guard Self.validFilename(download.filename) else { return nil }
        let url = directory.appendingPathComponent(download.filename)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return url
    }

    public func download(track: TrackRecord, transport: SourceTransport,
                         progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> PodcastDownload {
        try load()
        let key = Self.key(sourceID: track.sourceID, trackID: track.id)
        if let existing = records[key], file(for: existing) != nil { return existing }
        records[key] = nil
        guard activeKeys.insert(key).inserted else { throw PodcastDownloadError.alreadyDownloading }
        defer { activeKeys.remove(key) }
        guard let remote = track.url, ["http", "https"].contains(remote.scheme?.lowercased() ?? "") else {
            throw SourceNetworkError.invalidURL
        }
        let partial = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        _ = try await transport.download(from: remote, to: partial, progress: progress)
        try Task.checkCancellation()
        let size = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw SourceNetworkError.invalidResponse }
        let allowed = Set(["mp3", "m4a", "m4b", "mp4", "aac", "ogg", "opus", "flac", "wav", "aiff", "aif"])
        let suffix = remote.pathExtension.lowercased()
        let name = "\(key).\(allowed.contains(suffix) ? suffix : "audio")"
        let destination = directory.appendingPathComponent(name)
        // A cancelled or failed transfer never replaces a previously completed episode.
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: partial, to: destination)
        let record = PodcastDownload(id: key, sourceID: track.sourceID, trackID: track.id,
                                     title: track.title, filename: name, byteCount: Int64(size), downloadedAt: Date())
        records[key] = record
        do { try persist() }
        catch { records[key] = nil; try? FileManager.default.removeItem(at: destination); throw error }
        return record
    }

    /// Moves completed audio to Trash; there is no automatic expiry for explicit downloads.
    public func remove(id: String) throws {
        try load()
        guard let record = records[id], let url = file(for: record) else { return }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        records[id] = nil
        try persist()
    }

    private func load() throws {
        guard !loaded else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: manifest.path) {
            let values = try JSONDecoder().decode([PodcastDownload].self, from: Data(contentsOf: manifest))
            records = Dictionary(values.filter { file(for: $0) != nil }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        // Only this store's unfinished staging files are disposable after an interrupted app session.
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix(".") && url.pathExtension == "partial"
                && UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst())) != nil {
            try? FileManager.default.removeItem(at: url)
        }
        loaded = true
        try persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(records.values.sorted { $0.id < $1.id })
        try data.write(to: manifest, options: .atomic)
    }

    private nonisolated static func validFilename(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix(".") && !value.contains("/") && !value.contains("\\")
    }
}
