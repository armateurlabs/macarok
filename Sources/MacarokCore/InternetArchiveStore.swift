import Foundation
import GRDB

/// An Internet Archive item the user opened, saved, or is listening through.
public struct ArchiveItemRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable, Identifiable {
    public static let databaseTableName = "archiveItems"
    public var sourceID: String
    public var identifier: String
    public var title: String
    public var creator: String
    public var subtitle: String
    public var isSaved: Bool
    public var savedAt: Date?
    public var lastOpenedAt: Date
    public var resumeTrackID: String?
    public var resumePosition: Double
    public var resumeUpdatedAt: Date?

    public var id: String { sourceID + "/" + identifier }

    public init(sourceID: String, identifier: String, title: String, creator: String = "", subtitle: String = "",
                isSaved: Bool = false, savedAt: Date? = nil, lastOpenedAt: Date = Date(),
                resumeTrackID: String? = nil, resumePosition: Double = 0, resumeUpdatedAt: Date? = nil) {
        self.sourceID = sourceID; self.identifier = identifier; self.title = title; self.creator = creator
        self.subtitle = subtitle; self.isSaved = isSaved; self.savedAt = savedAt; self.lastOpenedAt = lastOpenedAt
        self.resumeTrackID = resumeTrackID; self.resumePosition = resumePosition; self.resumeUpdatedAt = resumeUpdatedAt
    }
}

public enum InternetArchiveStorage {
    public static func registerMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("internet-archive-v1") { db in
            try db.execute(sql: """
                CREATE TABLE archiveItems (
                    sourceID TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    identifier TEXT NOT NULL,
                    title TEXT NOT NULL,
                    creator TEXT NOT NULL DEFAULT '',
                    subtitle TEXT NOT NULL DEFAULT '',
                    isSaved BOOLEAN NOT NULL DEFAULT 0,
                    savedAt DATETIME,
                    lastOpenedAt DATETIME NOT NULL,
                    resumeTrackID TEXT,
                    resumePosition DOUBLE NOT NULL DEFAULT 0,
                    resumeUpdatedAt DATETIME,
                    PRIMARY KEY (sourceID, identifier)
                );
                CREATE TABLE archiveResponseCache (
                    key TEXT PRIMARY KEY NOT NULL,
                    payload BLOB NOT NULL,
                    fetchedAt DOUBLE NOT NULL
                );
                """)
        }
    }
}

extension LibraryStore: ArchiveResponseCache {
    public func cachedArchiveResponse(key: String, maxAge: TimeInterval?, now: Date) throws -> Data? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT payload, fetchedAt FROM archiveResponseCache WHERE key = ?", arguments: [key]) else { return nil }
            let fetchedAt: Double = row["fetchedAt"]
            if let maxAge, now.timeIntervalSince1970 - fetchedAt > maxAge { return nil }
            return row["payload"]
        }
    }

    public func saveArchiveResponse(_ data: Data, key: String, now: Date) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO archiveResponseCache(key, payload, fetchedAt) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET payload = excluded.payload, fetchedAt = excluded.fetchedAt
                """, arguments: [key, data, now.timeIntervalSince1970])
        }
    }

    /// Browsing caches are disposable; saved items keep their tracks in the library itself.
    public func pruneArchiveResponses(olderThan age: TimeInterval, now: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM archiveResponseCache WHERE fetchedAt < ?", arguments: [now.timeIntervalSince1970 - age])
        }
    }

    public func archiveItems(sourceID: String) throws -> [ArchiveItemRecord] {
        try database.read { db in
            try ArchiveItemRecord.fetchAll(db, sql: "SELECT * FROM archiveItems WHERE sourceID = ? ORDER BY lastOpenedAt DESC", arguments: [sourceID])
        }
    }

    public func archiveItem(sourceID: String, identifier: String) throws -> ArchiveItemRecord? {
        try database.read { db in
            try ArchiveItemRecord.fetchOne(db, sql: "SELECT * FROM archiveItems WHERE sourceID = ? AND identifier = ?", arguments: [sourceID, identifier])
        }
    }

    /// Records an opened item and its playable tracks together. Saved state and resume points are kept.
    @discardableResult
    public func materializeArchiveItem(_ item: ArchiveItemRecord, tracks: [TrackRecord], saved: Bool? = nil,
                                       now: Date = Date()) throws -> ArchiveItemRecord {
        try database.write { db in
            guard try SourceRecord.fetchOne(db, key: item.sourceID)?.kind == .internetArchive else {
                throw LibraryStoreError.sourceNotFound(item.sourceID)
            }
            var record = try ArchiveItemRecord.fetchOne(db, sql: "SELECT * FROM archiveItems WHERE sourceID = ? AND identifier = ?",
                                                        arguments: [item.sourceID, item.identifier]) ?? item
            record.title = item.title; record.creator = item.creator; record.subtitle = item.subtitle
            record.lastOpenedAt = now
            if let saved, saved != record.isSaved { record.isSaved = saved; record.savedAt = saved ? now : nil }
            try record.save(db)
            for track in tracks where track.sourceID == item.sourceID && track.remoteID == item.identifier {
                try Self.saveIndexedTrack(track, db: db)
            }
            return record
        }
    }

    public func setArchiveItemSaved(sourceID: String, identifier: String, saved: Bool, now: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE archiveItems SET isSaved = ?, savedAt = ? WHERE sourceID = ? AND identifier = ?",
                           arguments: [saved, saved ? now : nil, sourceID, identifier])
        }
    }

    public func saveArchiveResume(sourceID: String, identifier: String, trackID: String, position: Double, now: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: """
                UPDATE archiveItems SET resumeTrackID = ?, resumePosition = ?, resumeUpdatedAt = ?
                WHERE sourceID = ? AND identifier = ?
                """, arguments: [trackID, position.isFinite ? max(0, position) : 0, now, sourceID, identifier])
        }
    }

    /// Unsaved items leave library views unless the active playlist or a saved playlist still uses them.
    /// Their rows stay addressable so history and statistics survive a later visit.
    @discardableResult
    public func pruneArchiveTracks(sourceID: String) throws -> Bool {
        try database.write { db in
            var referenced = Set(try String.fetchAll(db, sql: """
                SELECT DISTINCT playlistEntries.trackID FROM playlistEntries
                JOIN tracks ON tracks.id = playlistEntries.trackID WHERE tracks.sourceID = ?
                """, arguments: [sourceID]))
            if let data = try Data.fetchOne(db, sql: "SELECT value FROM appState WHERE key = 'playbackQueue'"),
               let queue = try? JSONDecoder().decode(PlaybackQueueSnapshot.self, from: data) {
                referenced.formUnion(queue.trackIDs)
            }
            let saved = Set(try String.fetchAll(db, sql: "SELECT identifier FROM archiveItems WHERE sourceID = ? AND isSaved = 1", arguments: [sourceID]))
            let rows = try Row.fetchAll(db, sql: "SELECT id, remoteID FROM tracks WHERE sourceID = ? AND isAvailable = 1", arguments: [sourceID])
            let stale: [String] = rows.compactMap { row in
                let id: String = row["id"], item: String? = row["remoteID"]
                return item.map(saved.contains) == true || referenced.contains(id) ? nil : id
            }
            for id in stale {
                try db.execute(sql: "UPDATE tracks SET isAvailable = 0 WHERE id = ? AND sourceID = ?", arguments: [id, sourceID])
            }
            return !stale.isEmpty
        }
    }
}
