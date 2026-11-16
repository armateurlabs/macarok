import Foundation
import GRDB

/// Audio metadata can be reused while its size and modification date are unchanged.
/// External CUE text is also retained for dependency indexing; sheets and folder artwork are
/// deliberately resolved again on every scan.
public struct LocalScanFileCacheEntry: Codable, Sendable {
    public var path: String
    public var byteCount: Int64
    public var modifiedAt: Date
    public var metadata: AudioFileMetadata
    private var storedMetadata: AudioFileMetadata?
    private var storedMetadataData: Data?

    private enum CodingKeys: String, CodingKey { case path, byteCount, modifiedAt, metadata }

    public init(path: String, byteCount: Int64, modifiedAt: Date, metadata: AudioFileMetadata) {
        self.path = path
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.metadata = metadata
        self.metadata.artworkData = nil
        if self.metadata.duration?.isFinite == false { self.metadata.duration = nil }
    }

    mutating func rememberStoredMetadata(_ data: Data) {
        storedMetadata = metadata
        storedMetadataData = data
    }

    func reusesStoredMetadata(_ data: Data) -> Bool {
        guard let storedMetadata, storedMetadataData == data else { return false }
        return metadata.hasSameCacheMetadata(as: storedMetadata)
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
        migrator.registerMigration("local-scan-coverage-v2") { db in
            try db.execute(sql: """
                CREATE INDEX tracks_source_fileURL ON tracks(sourceID, fileURL);
                CREATE INDEX tracks_source_cuePath ON tracks(sourceID, cuePath);
                CREATE TABLE localScanCUEReferences (
                    sourceID TEXT NOT NULL,
                    cuePath TEXT NOT NULL,
                    audioPath TEXT NOT NULL,
                    PRIMARY KEY (sourceID, cuePath, audioPath),
                    FOREIGN KEY (sourceID, cuePath) REFERENCES localScanFiles(sourceID, path) ON DELETE CASCADE
                ) WITHOUT ROWID;
                CREATE INDEX localScanCUEReferences_audio ON localScanCUEReferences(sourceID, audioPath);
                """)
        }
    }
}

extension LibraryStore {
    public func localScanCache(sourceID: String, coverage: LocalScanCoverage = .all,
                               rootURL: URL? = nil) throws -> [String: LocalScanFileCacheEntry] {
        try database.read { db in
            let decoder = JSONDecoder()
            var entries: [String: LocalScanFileCacheEntry] = [:]
            let filter = try localScanCachePredicate(db: db, sourceID: sourceID, coverage: coverage, rootURL: rootURL)
            for row in try Row.fetchAll(db, sql: "SELECT path, byteCount, modifiedAt, metadata FROM localScanFiles WHERE sourceID = ? AND (\(filter.sql))",
                                       arguments: StatementArguments([sourceID] + filter.arguments)) {
                try Task.checkCancellation()
                let data: Data = row["metadata"]
                // A corrupt cache row is a miss; the next scan repairs it from the audio file.
                guard let metadata = try? decoder.decode(AudioFileMetadata.self, from: data) else { continue }
                let path: String = row["path"]
                let timestamp: Double = row["modifiedAt"]
                var entry = LocalScanFileCacheEntry(path: path, byteCount: row["byteCount"],
                    modifiedAt: Date(timeIntervalSinceReferenceDate: timestamp), metadata: metadata)
                entry.rememberStoredMetadata(data)
                entries[path] = entry
            }
            return entries
        }
    }

    public func saveLocalScanCache(sourceID: String, entries: [LocalScanFileCacheEntry], isComplete: Bool = true,
                                   coverage: LocalScanCoverage = .all, rootURL: URL? = nil) throws {
        // Encoding and comparison use a reader, leaving the writer available to playback state,
        // history, and scrobble submissions while a large unchanged catalog is checked.
        let changes = try database.read { db -> (updated: [(LocalScanFileCacheEntry, Data)], removed: [String]) in
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let filter = try localScanCachePredicate(db: db, sourceID: sourceID, coverage: coverage, rootURL: rootURL)
            let rows = try Row.fetchAll(db, sql: "SELECT path, byteCount, modifiedAt, metadata FROM localScanFiles WHERE sourceID = ? AND (\(filter.sql))",
                                        arguments: StatementArguments([sourceID] + filter.arguments))
            let previous = Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["path"] as String, row)
            })
            var activePaths = Set<String>()
            var updated: [(LocalScanFileCacheEntry, Data)] = []
            for entry in entries {
                try Task.checkCancellation()
                activePaths.insert(entry.path)
                // Fingerprint comparison precedes JSON work. A reused scanner value keeps a
                // private copy of its decoded metadata and exact blob, so changed artwork paths
                // or a concurrent cache update cannot be hidden by equal size/mtime values.
                if let old = previous[entry.path],
                   old["byteCount"] as Int64 == entry.byteCount,
                   old["modifiedAt"] as Double == entry.modifiedAt.timeIntervalSinceReferenceDate,
                   entry.reusesStoredMetadata(old["metadata"] as Data) { continue }
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
                if URL(fileURLWithPath: entry.path).pathExtension.lowercased() == "cue" {
                    try db.execute(sql: "DELETE FROM localScanCUEReferences WHERE sourceID = ? AND cuePath = ?", arguments: [sourceID, entry.path])
                    if let text = entry.metadata.embeddedCueSheet, let sheet = try? CUEParser.parse(text) {
                        let folder = URL(fileURLWithPath: entry.path).deletingLastPathComponent()
                        var references = Set<String>()
                        for name in sheet.fileNames {
                            let normalized = name.replacingOccurrences(of: "\\", with: "/")
                            references.insert(folder.appendingPathComponent(normalized).standardizedFileURL.path)
                            references.insert(folder.appendingPathComponent((normalized as NSString).lastPathComponent).standardizedFileURL.path)
                        }
                        for path in references {
                            try Task.checkCancellation()
                            try db.execute(sql: "INSERT OR IGNORE INTO localScanCUEReferences (sourceID, cuePath, audioPath) VALUES (?, ?, ?)",
                                           arguments: [sourceID, entry.path, path])
                        }
                    }
                }
            }
            for path in changes.removed {
                try Task.checkCancellation()
                try db.execute(sql: "DELETE FROM localScanFiles WHERE sourceID = ? AND path = ?", arguments: [sourceID, path])
            }
            try Task.checkCancellation()
        }
    }

    private func localScanCachePredicate(db: Database, sourceID: String, coverage: LocalScanCoverage,
                                         rootURL: URL?) throws -> (sql: String, arguments: [String]) {
        guard coverage.normalized != .all else { return ("1", []) }
        guard let root = try rootURL ?? SourceRecord.fetchOne(db, key: sourceID)?.url else { return ("0", []) }
        return coverage.predicate(column: "path", rootURL: root)
    }
}

private extension AudioFileMetadata {
    func hasSameCacheMetadata(as other: AudioFileMetadata) -> Bool {
        title == other.title && artist == other.artist && albumArtist == other.albumArtist &&
        album == other.album && year == other.year && genre == other.genre &&
        trackNumber == other.trackNumber && discNumber == other.discNumber &&
        duration == other.duration && format == other.format && artworkPath == other.artworkPath &&
        artworkMIMEType == other.artworkMIMEType && embeddedCueSheet == other.embeddedCueSheet &&
        sampleRate == other.sampleRate && channels == other.channels && bitsPerSample == other.bitsPerSample &&
        cuePoints == other.cuePoints
    }
}
