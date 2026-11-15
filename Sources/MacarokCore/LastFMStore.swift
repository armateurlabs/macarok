import Foundation
import GRDB

public struct LastFMPreferences: Codable, Sendable, Equatable {
    public var enabled = false
    public var sharesNowPlaying = true
    public var excludedSourceIDs: Set<String> = []
    public init() { }
}

public struct LastFMOutboxEntry: Sendable {
    public var submission: LastFMSubmission
    public var attempts: Int
    public var nextAttemptAt: Date
}

public struct LastFMOutboxSummary: Sendable {
    public var pending: Int
    public var ignored: Int
    public var failed: Int
}

public enum LastFMStoreStorage {
    public static func registerMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("lastfm-outbox-v1") { db in
            // No library foreign keys: an authorized listening event survives removal of its source.
            try db.execute(sql: """
                CREATE TABLE lastFMOutbox (
                    accountID TEXT NOT NULL,
                    occurrenceID TEXT NOT NULL,
                    startedAt DOUBLE NOT NULL,
                    payload BLOB NOT NULL,
                    state TEXT NOT NULL DEFAULT 'pending',
                    attempts INTEGER NOT NULL DEFAULT 0,
                    nextAttemptAt DOUBLE NOT NULL DEFAULT 0,
                    ignoredCode INTEGER,
                    message TEXT,
                    PRIMARY KEY (accountID, occurrenceID)
                );
                CREATE INDEX lastFMOutbox_pending ON lastFMOutbox(accountID, state, startedAt);
                """)
        }
    }
}

extension LibraryStore {
    public func lastFMPreferences() throws -> LastFMPreferences {
        guard let data = try value(forKey: "Macarok.lastfm.preferences") else { return LastFMPreferences() }
        return try JSONDecoder().decode(LastFMPreferences.self, from: data)
    }

    public func saveLastFMPreferences(_ preferences: LastFMPreferences) throws {
        try setValue(JSONEncoder().encode(preferences), forKey: "Macarok.lastfm.preferences")
    }

    public func enqueueLastFM(_ submission: LastFMSubmission, accountID: String) throws {
        let data = try JSONEncoder().encode(submission)
        try database.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO lastFMOutbox(accountID, occurrenceID, startedAt, payload)
                VALUES (?, ?, ?, ?)
                """, arguments: [accountID, submission.id, submission.startedAt.timeIntervalSince1970, data])
        }
    }

    /// A future retry at the head blocks newer scrobbles, preserving chronological delivery.
    public func lastFMBatch(accountID: String, at date: Date = Date(), limit: Int = 50) throws -> [LastFMOutboxEntry] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM lastFMOutbox WHERE accountID = ? AND state = 'pending'
                ORDER BY startedAt, occurrenceID LIMIT ?
                """, arguments: [accountID, min(50, max(1, limit))])
            return try rows.prefix { (row: Row) in let next: Double = row["nextAttemptAt"]; return next <= date.timeIntervalSince1970 }.map { row in
                let data: Data = row["payload"]
                return LastFMOutboxEntry(submission: try JSONDecoder().decode(LastFMSubmission.self, from: data),
                                         attempts: row["attempts"], nextAttemptAt: Date(timeIntervalSince1970: row["nextAttemptAt"]))
            }
        }
    }

    public func nextLastFMAttempt(accountID: String) throws -> Date? {
        try database.read { db in
            let value = try Double.fetchOne(db, sql: """
                SELECT nextAttemptAt FROM lastFMOutbox WHERE accountID = ? AND state = 'pending'
                ORDER BY startedAt, occurrenceID LIMIT 1
                """, arguments: [accountID])
            return value.map(Date.init(timeIntervalSince1970:))
        }
    }

    public func lastFMSummary(accountID: String) throws -> LastFMOutboxSummary {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT state, COUNT(*) AS count FROM lastFMOutbox WHERE accountID = ? GROUP BY state", arguments: [accountID])
            var counts: [String: Int] = [:]
            for row in rows { let state: String = row["state"]; let count: Int = row["count"]; counts[state] = count }
            return LastFMOutboxSummary(pending: counts["pending"] ?? 0, ignored: counts["ignored"] ?? 0, failed: counts["failed"] ?? 0)
        }
    }

    public func completeLastFM(_ outcomes: [LastFMSubmissionOutcome], accountID: String) throws {
        try database.write { db in
            for outcome in outcomes {
                try db.execute(sql: """
                    UPDATE lastFMOutbox SET state = ?, ignoredCode = ?, message = ?
                    WHERE accountID = ? AND occurrenceID = ? AND state = 'pending'
                    """, arguments: [outcome.ignoredCode == 0 ? "accepted" : "ignored", outcome.ignoredCode,
                                      outcome.message, accountID, outcome.id])
            }
        }
    }

    public func deferLastFM(_ ids: [String], accountID: String, until date: Date) throws {
        try database.write { db in
            for id in ids {
                try db.execute(sql: """
                    UPDATE lastFMOutbox SET attempts = attempts + 1, nextAttemptAt = ?
                    WHERE accountID = ? AND occurrenceID = ? AND state = 'pending'
                    """, arguments: [date.timeIntervalSince1970, accountID, id])
            }
        }
    }

    public func failLastFM(_ ids: [String], accountID: String, message: String) throws {
        try database.write { db in
            for id in ids {
                try db.execute(sql: """
                    UPDATE lastFMOutbox SET state = 'failed', message = ?
                    WHERE accountID = ? AND occurrenceID = ? AND state = 'pending'
                    """, arguments: [message, accountID, id])
            }
        }
    }

    /// Terminal rows retain the occurrence identity so reconnecting cannot submit a play twice.
    public func clearPendingLastFM(accountID: String) throws {
        try database.write { try $0.execute(sql: "DELETE FROM lastFMOutbox WHERE accountID = ? AND state = 'pending'", arguments: [accountID]) }
    }
}
