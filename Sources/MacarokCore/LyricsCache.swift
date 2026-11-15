import Foundation
import GRDB

public struct LyricsCacheEntry: Sendable, Equatable {
    public var result: LyricsLookupResult
    public var isManual: Bool
    public var checkedAt: Date
    public var expiresAt: Date?
}

public enum LyricsCacheStorage {
    public static func registerMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("lyrics-cache-v1") { db in
            try db.execute(sql: """
                CREATE TABLE lyricsCache (
                    sourceID TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    trackID TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
                    fingerprint TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    manual BOOLEAN NOT NULL DEFAULT 0,
                    checkedAt DOUBLE NOT NULL,
                    expiresAt DOUBLE,
                    PRIMARY KEY (sourceID, trackID)
                );
                """)
        }
    }
}

extension LibraryStore {
    public func cachedLyrics(for query: LyricsLookupQuery, now: Date = Date()) throws -> LyricsCacheEntry? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM lyricsCache WHERE sourceID = ? AND trackID = ? AND (manual = 1 OR fingerprint = ?)",
                                             arguments: [query.sourceID, query.trackID, query.fingerprint]) else { return nil }
            let expiry: Double? = row["expiresAt"]
            if let expiry, expiry <= now.timeIntervalSince1970 { return nil }
            let payload: Data = row["payload"]
            let result = try JSONDecoder().decode(LyricsLookupResult.self, from: payload)
            return LyricsCacheEntry(result: result, isManual: row["manual"],
                                    checkedAt: Date(timeIntervalSince1970: row["checkedAt"]),
                                    expiresAt: expiry.map(Date.init(timeIntervalSince1970:)))
        }
    }

    public func saveLyrics(_ result: LyricsLookupResult, for query: LyricsLookupQuery,
                           manual: Bool = false, now: Date = Date()) throws {
        if let document = result.document, !document.hasContent {
            throw LyricsError.invalidDocument("Enter lyrics before saving them.")
        }
        if manual, result == .notFound { throw LyricsError.invalidDocument("An empty search result cannot be a manual override.") }
        let payload = try JSONEncoder().encode(result)
        let expiresAt: Double? = result == .notFound ? now.addingTimeInterval(15 * 60).timeIntervalSince1970 : nil
        try database.write { db in
            guard let track = try TrackRecord.fetchOne(db, key: query.trackID), track.sourceID == query.sourceID else {
                throw LibraryStoreError.trackNotFound(query.trackID)
            }
            let currentFingerprint = LyricsLookupQuery(track: track).fingerprint
            // Deliberate edits target track identity; automatic responses still target the metadata queried.
            guard manual || currentFingerprint == query.fingerprint else { return }
            try db.execute(sql: """
                INSERT INTO lyricsCache(sourceID, trackID, fingerprint, payload, manual, checkedAt, expiresAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(sourceID, trackID) DO UPDATE SET
                    fingerprint = excluded.fingerprint, payload = excluded.payload,
                    manual = excluded.manual, checkedAt = excluded.checkedAt, expiresAt = excluded.expiresAt
                WHERE lyricsCache.manual = 0 OR excluded.manual = 1
                """, arguments: [query.sourceID, query.trackID, manual ? currentFingerprint : query.fingerprint, payload, manual,
                                  now.timeIntervalSince1970, expiresAt])
        }
    }

    public func removeLyrics(for query: LyricsLookupQuery) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM lyricsCache WHERE sourceID = ? AND trackID = ?", arguments: [query.sourceID, query.trackID])
        }
    }
}
