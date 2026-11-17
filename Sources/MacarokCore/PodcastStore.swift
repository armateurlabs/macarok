import Foundation
import GRDB

/// Show information kept between launches: the feed description is not part of any track.
public struct PodcastShowRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable, Identifiable {
    public static let databaseTableName = "podcastShows"
    public var sourceID: String
    public var title: String
    public var author: String
    public var description: String
    public var artworkURL: String?
    public var link: String?
    public var isSerial: Bool
    public var etag: String?
    public var lastModified: String?
    public var refreshedAt: Date?
    public var lastError: String?

    public var id: String { sourceID }
    public var validators: PodcastFeedValidators { PodcastFeedValidators(etag: etag, lastModified: lastModified) }

    public init(sourceID: String, title: String, author: String = "", description: String = "", artworkURL: String? = nil,
                link: String? = nil, isSerial: Bool = false, etag: String? = nil, lastModified: String? = nil,
                refreshedAt: Date? = nil, lastError: String? = nil) {
        self.sourceID = sourceID; self.title = title; self.author = author; self.description = description
        self.artworkURL = artworkURL; self.link = link; self.isSerial = isSerial; self.etag = etag
        self.lastModified = lastModified; self.refreshedAt = refreshedAt; self.lastError = lastError
    }

    public init(sourceID: String, feed: PodcastFeed, validators: PodcastFeedValidators, refreshedAt: Date) {
        self.init(sourceID: sourceID, title: feed.title, author: feed.author, description: feed.description,
                  artworkURL: feed.artworkURL?.absoluteString, link: feed.link?.absoluteString, isSerial: feed.isSerial,
                  etag: validators.etag, lastModified: validators.lastModified, refreshedAt: refreshedAt)
    }
}

/// Listening position of one episode. Rows are keyed by track identity, not by a foreign key on
/// `tracks`, because a feed refresh may rewrite the episode rows.
public struct PodcastProgressRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable, Identifiable {
    public static let databaseTableName = "podcastProgress"
    public var trackID: String
    public var sourceID: String
    public var position: Double
    public var duration: Double
    public var isFinished: Bool
    public var updatedAt: Date

    public var id: String { trackID }

    public init(trackID: String, sourceID: String, position: Double, duration: Double, isFinished: Bool, updatedAt: Date = Date()) {
        self.trackID = trackID; self.sourceID = sourceID
        self.position = position.isFinite ? max(0, position) : 0
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.isFinished = isFinished; self.updatedAt = updatedAt
    }
}

public enum PodcastStorage {
    public static func registerMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("podcast-v1") { db in
            try db.execute(sql: """
                CREATE TABLE podcastShows (
                    sourceID TEXT PRIMARY KEY NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    author TEXT NOT NULL DEFAULT '',
                    description TEXT NOT NULL DEFAULT '',
                    artworkURL TEXT,
                    link TEXT,
                    isSerial BOOLEAN NOT NULL DEFAULT 0,
                    etag TEXT,
                    lastModified TEXT,
                    refreshedAt DATETIME,
                    lastError TEXT
                );
                CREATE TABLE podcastEpisodeNotes (
                    trackID TEXT PRIMARY KEY NOT NULL,
                    sourceID TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    notes TEXT NOT NULL DEFAULT '',
                    link TEXT
                );
                CREATE INDEX podcastEpisodeNotes_source ON podcastEpisodeNotes(sourceID);
                CREATE TABLE podcastProgress (
                    trackID TEXT PRIMARY KEY NOT NULL,
                    sourceID TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    position DOUBLE NOT NULL,
                    duration DOUBLE NOT NULL,
                    isFinished BOOLEAN NOT NULL DEFAULT 0,
                    updatedAt DATETIME NOT NULL
                );
                """)
        }
        // Notes now keep their paragraphs; refetch every feed once instead of answering 304.
        migrator.registerMigration("podcast-v2-structured-notes") { db in
            try db.execute(sql: "UPDATE podcastShows SET etag = NULL, lastModified = NULL, refreshedAt = NULL")
        }
        migrator.registerMigration("podcast-v3-chapters") { db in
            try db.execute(sql: """
                ALTER TABLE podcastEpisodeNotes ADD COLUMN chaptersURL TEXT;
                ALTER TABLE podcastEpisodeNotes ADD COLUMN chapters TEXT;
                CREATE TABLE podcastChapterCache (
                    trackID TEXT PRIMARY KEY NOT NULL,
                    sourceID TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    payload BLOB NOT NULL,
                    fetchedAt DATETIME NOT NULL
                );
                UPDATE podcastShows SET etag = NULL, lastModified = NULL, refreshedAt = NULL;
                """)
        }
    }
}

extension LibraryStore {
    public func podcastShows() throws -> [String: PodcastShowRecord] {
        try database.read { db in
            Dictionary(uniqueKeysWithValues: try PodcastShowRecord.fetchAll(db).map { ($0.sourceID, $0) })
        }
    }

    /// Stores a fetched feed: show information, validators, and every episode's notes.
    public func savePodcastFeed(sourceID: String, feed: PodcastFeed, validators: PodcastFeedValidators, now: Date = Date()) throws {
        try database.write { db in
            guard try SourceRecord.fetchOne(db, key: sourceID) != nil else { throw LibraryStoreError.sourceNotFound(sourceID) }
            try PodcastShowRecord(sourceID: sourceID, feed: feed, validators: validators, refreshedAt: now).save(db)
            try db.execute(sql: "DELETE FROM podcastEpisodeNotes WHERE sourceID = ?", arguments: [sourceID])
            for episode in feed.episodes where !episode.description.isEmpty || episode.link != nil
                || episode.chaptersURL != nil || !episode.chapters.isEmpty {
                let chapters = episode.chapters.isEmpty ? nil : String(data: try JSONEncoder().encode(episode.chapters), encoding: .utf8)
                try db.execute(sql: """
                    INSERT OR REPLACE INTO podcastEpisodeNotes(trackID, sourceID, notes, link, chaptersURL, chapters) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [PodcastEpisode.trackID(sourceID: sourceID, episodeID: episode.id), sourceID,
                                    episode.description, episode.link?.absoluteString, episode.chaptersURL?.absoluteString, chapters])
            }
        }
    }

    /// Records a refresh attempt that did not replace the feed: unchanged (304) or failed.
    public func markPodcastRefresh(sourceID: String, error: String?, now: Date = Date()) throws {
        try database.write { db in
            if error == nil {
                try db.execute(sql: "UPDATE podcastShows SET refreshedAt = ?, lastError = NULL WHERE sourceID = ?", arguments: [now, sourceID])
            } else {
                try db.execute(sql: "UPDATE podcastShows SET lastError = ? WHERE sourceID = ?", arguments: [error, sourceID])
            }
        }
    }

    public func podcastNotes(trackID: String) throws -> (notes: String, link: String?)? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT notes, link FROM podcastEpisodeNotes WHERE trackID = ?", arguments: [trackID])
                .map { ($0["notes"], $0["link"]) }
        }
    }

    /// Chapter sources stored with an episode's notes: the JSON address and any chapters in the feed.
    public func podcastChapterSources(trackID: String) throws -> (url: URL?, chapters: [PodcastChapter], notes: String) {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT notes, chaptersURL, chapters FROM podcastEpisodeNotes WHERE trackID = ?",
                                             arguments: [trackID]) else { return (nil, [], "") }
            let url = (row["chaptersURL"] as String?).flatMap(URL.init(string:))
            let chapters = (row["chapters"] as String?).flatMap { try? JSONDecoder().decode([PodcastChapter].self, from: Data($0.utf8)) } ?? []
            return (url, chapters, row["notes"])
        }
    }

    public func cachedPodcastChapters(trackID: String) throws -> Data? {
        try database.read { db in try Data.fetchOne(db, sql: "SELECT payload FROM podcastChapterCache WHERE trackID = ?", arguments: [trackID]) }
    }

    public func savePodcastChapters(_ payload: Data, trackID: String, sourceID: String, now: Date = Date()) throws {
        try database.write { db in
            guard try SourceRecord.fetchOne(db, key: sourceID) != nil else { return }
            try db.execute(sql: "INSERT OR REPLACE INTO podcastChapterCache(trackID, sourceID, payload, fetchedAt) VALUES (?, ?, ?, ?)",
                           arguments: [trackID, sourceID, payload, now])
        }
    }

    public func podcastProgress() throws -> [String: PodcastProgressRecord] {
        try database.read { db in
            Dictionary(uniqueKeysWithValues: try PodcastProgressRecord.fetchAll(db).map { ($0.trackID, $0) })
        }
    }

    public func savePodcastProgress(_ records: [PodcastProgressRecord]) throws {
        try database.write { db in
            for record in records where try SourceRecord.fetchOne(db, key: record.sourceID) != nil { try record.save(db) }
        }
    }

    public func deletePodcastProgress(trackIDs: [String]) throws {
        guard !trackIDs.isEmpty else { return }
        try database.write { db in
            for id in trackIDs { try db.execute(sql: "DELETE FROM podcastProgress WHERE trackID = ?", arguments: [id]) }
        }
    }
}
