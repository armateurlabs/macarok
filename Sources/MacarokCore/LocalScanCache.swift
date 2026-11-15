import Foundation
import GRDB

/// A physical audio file's metadata can be reused while its size and modification date are unchanged.
/// CUE sheets and folder artwork are deliberately resolved again on every scan.
public struct LocalScanFileCacheEntry: Codable, Sendable {
    public var path: String
    public var byteCount: Int64
    public var modifiedAt: Date
    public var metadata: AudioFileMetadata

    public init(path: String, byteCount: Int64, modifiedAt: Date, metadata: AudioFileMetadata) {
        self.path = path
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.metadata = metadata
        self.metadata.artworkData = nil
        if self.metadata.duration?.isFinite == false { self.metadata.duration = nil }
    }

    func matches(_ fingerprint: LocalScanFileFingerprint) -> Bool {
        byteCount == fingerprint.byteCount && modifiedAt == fingerprint.modifiedAt &&
            (metadata.artworkPath.map { FileManager.default.fileExists(atPath: $0) } ?? true)
    }
}

struct LocalScanFileFingerprint: Equatable {
    var byteCount: Int64
    var modifiedAt: Date

    init(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, let date = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown)
        }
        byteCount = size.int64Value
        modifiedAt = date
    }
}

enum LocalScanCacheStorage {
    static func registerMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("local-scan-cache-v1") { db in
            try db.execute(sql: """
                CREATE TABLE localScanFiles (
                    sourceID TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    path TEXT NOT NULL,
                    byteCount INTEGER NOT NULL,
                    modifiedAt DOUBLE NOT NULL,
                    metadata BLOB NOT NULL,
                    PRIMARY KEY (sourceID, path)
                ) WITHOUT ROWID;
                """)
        }
    }
}

extension LibraryStore {
    public func localScanCache(sourceID: String) throws -> [String: LocalScanFileCacheEntry] {
        try database.read { db in
            let decoder = JSONDecoder()
            var entries: [String: LocalScanFileCacheEntry] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT path, byteCount, modifiedAt, metadata FROM localScanFiles WHERE sourceID = ?", arguments: [sourceID]) {
                try Task.checkCancellation()
                let data: Data = row["metadata"]
                // A corrupt cache row is a miss; the next scan repairs it from the audio file.
                guard let metadata = try? decoder.decode(AudioFileMetadata.self, from: data) else { continue }
                let path: String = row["path"]
                let timestamp: Double = row["modifiedAt"]
                entries[path] = LocalScanFileCacheEntry(path: path, byteCount: row["byteCount"],
                    modifiedAt: Date(timeIntervalSinceReferenceDate: timestamp), metadata: metadata)
            }
            return entries
        }
    }

    public func saveLocalScanCache(sourceID: String, entries: [LocalScanFileCacheEntry], isComplete: Bool = true) throws {
        // Encoding and comparison use a reader, leaving the writer available to playback state,
        // history, and scrobble submissions while a large unchanged catalog is checked.
        let changes = try database.read { db -> (updated: [(LocalScanFileCacheEntry, Data)], removed: [String]) in
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let rows = try Row.fetchAll(db, sql: "SELECT path, byteCount, modifiedAt, metadata FROM localScanFiles WHERE sourceID = ?", arguments: [sourceID])
            let previous = Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["path"] as String, row)
            })
            var activePaths = Set<String>()
            var updated: [(LocalScanFileCacheEntry, Data)] = []
            for entry in entries {
                try Task.checkCancellation()
                activePaths.insert(entry.path)
                var metadata = entry.metadata
                metadata.artworkData = nil
                if metadata.duration?.isFinite == false { metadata.duration = nil }
                let data = try encoder.encode(metadata)
                if let old = previous[entry.path],
                   old["byteCount"] as Int64 == entry.byteCount,
                   old["modifiedAt"] as Double == entry.modifiedAt.timeIntervalSinceReferenceDate,
                   old["metadata"] as Data == data { continue }
                updated.append((entry, data))
            }
            return (updated, isComplete ? previous.keys.filter { !activePaths.contains($0) } : [])
        }
        guard !changes.updated.isEmpty || !changes.removed.isEmpty else { try Task.checkCancellation(); return }
        try database.write { db in
            try Task.checkCancellation()
            for (entry, data) in changes.updated {
                try Task.checkCancellation()
                try db.execute(sql: """
                    INSERT INTO localScanFiles (sourceID, path, byteCount, modifiedAt, metadata)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(sourceID, path) DO UPDATE SET
                        byteCount = excluded.byteCount, modifiedAt = excluded.modifiedAt, metadata = excluded.metadata
                    WHERE localScanFiles.byteCount != excluded.byteCount OR
                          localScanFiles.modifiedAt != excluded.modifiedAt OR localScanFiles.metadata != excluded.metadata
                    """, arguments: [sourceID, entry.path, entry.byteCount, entry.modifiedAt.timeIntervalSinceReferenceDate, data])
            }
            for path in changes.removed {
                try Task.checkCancellation()
                try db.execute(sql: "DELETE FROM localScanFiles WHERE sourceID = ? AND path = ?", arguments: [sourceID, path])
            }
            try Task.checkCancellation()
        }
    }
}
