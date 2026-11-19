import Foundation
import GRDB

private struct QueueResumeCheckpoint: Codable {
    let currentIndex: Int
    let position: Double
}

public enum LibraryStoreError: LocalizedError {
    case trackNotFound(String)
    case sourceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .trackNotFound: "The track is no longer present in the library."
        case .sourceNotFound: "The source is no longer present in the library."
        }
    }
}

/// SQLite is the durable home of the index and user data. Reads can run while a scan writes.
public final class LibraryStore: @unchecked Sendable {
    public let database: DatabasePool

    public static var defaultURL: URL {
        let directory: URL
        if let path = ProcessInfo.processInfo.environment["MACAROK_DATA_DIRECTORY"], !path.isEmpty {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Macarok", isDirectory: true)
        }
        return directory.appendingPathComponent("library.sqlite")
    }

    public init(url: URL = LibraryStore.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        database = try DatabasePool(path: url.path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("library-v1") { db in
            try db.execute(sql: """
                CREATE TABLE sources (
                    id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    name TEXT NOT NULL,
                    location TEXT NOT NULL,
                    createdAt DATETIME NOT NULL,
                    bookmarkData BLOB
                );
                CREATE TABLE tracks (
                    id TEXT PRIMARY KEY NOT NULL,
                    sourceID TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    albumID TEXT NOT NULL,
                    title TEXT NOT NULL,
                    artist TEXT NOT NULL,
                    albumArtist TEXT NOT NULL,
                    album TEXT NOT NULL,
                    year INTEGER,
                    genre TEXT,
                    trackNumber INTEGER,
                    discNumber INTEGER,
                    duration DOUBLE NOT NULL DEFAULT 0,
                    fileURL TEXT,
                    remoteID TEXT,
                    format TEXT NOT NULL,
                    artworkPath TEXT,
                    cuePath TEXT,
                    startTime DOUBLE,
                    endTime DOUBLE,
                    addedAt DATETIME NOT NULL,
                    lastPlayedAt DATETIME,
                    playCount INTEGER NOT NULL DEFAULT 0,
                    rating INTEGER NOT NULL DEFAULT 0 CHECK(rating BETWEEN 0 AND 5),
                    isAvailable BOOLEAN NOT NULL DEFAULT 1,
                    metadataLocked BOOLEAN NOT NULL DEFAULT 0
                );
                CREATE INDEX tracks_source ON tracks(sourceID, isAvailable);
                CREATE INDEX tracks_album ON tracks(sourceID, albumID);
                CREATE INDEX tracks_lastPlayed ON tracks(sourceID, lastPlayedAt);
                CREATE VIRTUAL TABLE trackSearch USING fts5(
                    title, artist, album, albumArtist, genre,
                    content = 'tracks', content_rowid = 'rowid',
                    tokenize = 'unicode61 remove_diacritics 2'
                );
                CREATE TRIGGER tracks_search_insert AFTER INSERT ON tracks BEGIN
                    INSERT INTO trackSearch(rowid, title, artist, album, albumArtist, genre)
                    VALUES (new.rowid, new.title, new.artist, new.album, new.albumArtist, new.genre);
                END;
                CREATE TRIGGER tracks_search_delete AFTER DELETE ON tracks BEGIN
                    INSERT INTO trackSearch(trackSearch, rowid, title, artist, album, albumArtist, genre)
                    VALUES ('delete', old.rowid, old.title, old.artist, old.album, old.albumArtist, old.genre);
                END;
                CREATE TRIGGER tracks_search_update AFTER UPDATE OF title, artist, album, albumArtist, genre ON tracks BEGIN
                    INSERT INTO trackSearch(trackSearch, rowid, title, artist, album, albumArtist, genre)
                    VALUES ('delete', old.rowid, old.title, old.artist, old.album, old.albumArtist, old.genre);
                    INSERT INTO trackSearch(rowid, title, artist, album, albumArtist, genre)
                    VALUES (new.rowid, new.title, new.artist, new.album, new.albumArtist, new.genre);
                END;
                CREATE TABLE playlists (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL
                );
                CREATE TABLE playlistEntries (
                    id INTEGER PRIMARY KEY,
                    playlistID TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
                    trackID TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL
                );
                CREATE INDEX playlistEntries_order ON playlistEntries(playlistID, position);
                CREATE TABLE listeningHistory (
                    id TEXT PRIMARY KEY NOT NULL,
                    trackID TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
                    playedAt DATETIME NOT NULL
                );
                CREATE INDEX listeningHistory_date ON listeningHistory(playedAt);
                CREATE TABLE appState (
                    key TEXT PRIMARY KEY NOT NULL,
                    value BLOB NOT NULL
                );
                """)
        }
        migrator.registerMigration("library-v2-remote-paths") { db in
            try db.execute(sql: "ALTER TABLE tracks ADD COLUMN remotePath TEXT")
            try db.execute(sql: "ALTER TABLE tracks ADD COLUMN coverArtID TEXT")
        }
        LyricsCacheStorage.registerMigration(&migrator)
        RadioStoreStorage.registerMigration(&migrator)
        LastFMStoreStorage.registerMigration(&migrator)
        LocalScanCacheStorage.registerMigration(&migrator)
        SimilarityCacheStorage.registerMigration(&migrator)
        InternetArchiveStorage.registerMigration(&migrator)
        PodcastStorage.registerMigration(&migrator)
        ArtistArtworkStorage.registerMigration(&migrator)
        SongLinkStorage.registerMigration(&migrator)
        try migrator.migrate(database)
    }

    public func sources() throws -> [SourceRecord] {
        try database.read { try SourceRecord.fetchAll($0, sql: "SELECT * FROM sources ORDER BY createdAt, name COLLATE NOCASE") }
    }

    public func saveSource(_ source: SourceRecord) throws {
        try database.write { try source.save($0) }
    }

    /// A connection becomes visible together with its initial catalog, or neither is committed.
    public func saveSource(_ source: SourceRecord, tracks: [TrackRecord]) throws {
        try database.write { db in
            try Task.checkCancellation()
            try source.save(db)
            for track in tracks where track.sourceID == source.id {
                try Task.checkCancellation()
                try Self.saveIndexedTrack(track, db: db)
            }
            try Task.checkCancellation()
        }
    }

    public func deleteSource(id: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM sources WHERE id = ?", arguments: [id])
        }
    }

    public func tracks(sourceID: String, query: String = "", ordered: Bool = true) throws -> [TrackRecord] {
        try tracks(scope: .source(sourceID), query: query, ordered: ordered)
    }

    public func tracks(scope: LibraryScope, query: String = "", ordered: Bool = true) throws -> [TrackRecord] {
        let search = Self.searchPattern(query)
        return try database.read { db in
            var sql = "SELECT tracks.* FROM tracks"
            var arguments = StatementArguments()
            if search != nil { sql += " JOIN trackSearch ON trackSearch.rowid = tracks.rowid" }
            sql += " WHERE tracks.isAvailable = 1"
            switch scope {
            case .all: break
            case .source(let id):
                sql += " AND tracks.sourceID = ?"
                arguments += [id]
            case .podcasts:
                sql += " AND tracks.sourceID IN (SELECT id FROM sources WHERE kind IN (?, ?))"
                arguments += [SourceKind.podcasts.rawValue, SourceKind.podcastDirectory.rawValue]
            }
            if let search {
                sql += " AND trackSearch MATCH ?"
                arguments += [search]
            }
            let values = try TrackRecord.fetchAll(db, sql: sql, arguments: arguments)
            return ordered ? values.sorted(by: TrackRecord.libraryOrder) : values
        }
    }

    public func allTracks() throws -> [TrackRecord] {
        try database.read { try TrackRecord.fetchAll($0).sorted(by: TrackRecord.libraryOrder) }
    }

    public func track(id: String) throws -> TrackRecord? {
        try database.read { try TrackRecord.fetchOne($0, key: id) }
    }

    public func albums(sourceID: String, query: String = "") throws -> [AlbumRecord] {
        let tracks = try tracks(sourceID: sourceID, query: query)
        return Dictionary(grouping: tracks, by: \.albumID).values.map { AlbumRecord(tracks: $0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func artists(sourceID: String, query: String = "") throws -> [ArtistSummary] {
        let tracks = try tracks(sourceID: sourceID, query: query)
        return Dictionary(grouping: tracks, by: \.albumArtist).map { name, tracks in
            ArtistSummary(name: name, sourceID: sourceID, tracks: tracks)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Scans update their index fields, while user statistics and locked corrections survive.
    @discardableResult
    public func upsertTracks(_ tracks: [TrackRecord]) throws -> Bool {
        try database.write { db in
            var changed = false
            for track in tracks {
                try Task.checkCancellation()
                let saved = try Self.saveIndexedTrack(track, db: db)
                changed = saved || changed
            }
            return changed
        }
    }

    /// A completed download may fill only the still-current, uncached cover references.
    public func cacheRemoteArtwork(sourceID: String, albumID: String, coverArtID: String, path: String) throws {
        try database.write { db in
            try db.execute(sql: """
                UPDATE tracks SET artworkPath = ?
                WHERE sourceID = ? AND albumID = ? AND coverArtID = ? AND artworkPath IS NULL
                """, arguments: [path, sourceID, albumID, coverArtID])
        }
    }

    @discardableResult
    public func replaceSourceTracks(sourceID: String, with tracks: [TrackRecord],
                                    coverage: LocalScanCoverage = .all, rootURL: URL? = nil) throws -> Bool {
        try database.write { db in
            try Task.checkCancellation()
            let coverage = coverage.normalized
            var predicate = "1"
            var arguments = [sourceID]
            if coverage != .all {
                guard let source = try SourceRecord.fetchOne(db, key: sourceID), source.kind == .local,
                      let root = rootURL ?? source.url else { throw LibraryScannerError.unsupportedSource }
                let file = coverage.predicate(column: "fileURL", rootURL: root, encodedURL: true)
                let cue = coverage.predicate(column: "cuePath", rootURL: root)
                predicate = "((\(file.sql)) OR (\(cue.sql)))"
                arguments += file.arguments + cue.arguments
            }
            var previous = Dictionary(uniqueKeysWithValues: try TrackRecord.fetchAll(db,
                sql: "SELECT * FROM tracks WHERE sourceID = ? AND \(predicate)",
                arguments: StatementArguments(arguments)).map { ($0.id, $0) })
            var activeIDs = Set<String>()
            var changed = false
            for track in tracks where track.sourceID == sourceID {
                try Task.checkCancellation()
                var value = track
                value.isAvailable = true
                activeIDs.insert(value.id)
                // An expanded/new CUE can introduce a record outside the original SQL coverage.
                // Fetch its existing row before preserving statistics and locked metadata.
                let old = try previous[value.id] ?? TrackRecord.fetchOne(db, key: value.id)
                let saved = try Self.saveIndexedTrack(value, preserving: old, db: db)
                changed = old != saved || changed
                previous[value.id] = saved
            }
            for track in previous.values where track.isAvailable && !activeIDs.contains(track.id) {
                try Task.checkCancellation()
                try db.execute(sql: "UPDATE tracks SET isAvailable = 0 WHERE id = ? AND sourceID = ?", arguments: [track.id, sourceID])
                changed = true
            }
            try Task.checkCancellation()
            return changed
        }
    }

    /// A missing file remains addressable by playlists and history, but leaves normal library views.
    /// Returns whether any track's availability changed.
    @discardableResult
    public func reconcileTracks(sourceID: String, activeIDs: Set<String>) throws -> Bool {
        try database.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, isAvailable FROM tracks WHERE sourceID = ?", arguments: [sourceID])
            var missing: [String] = []
            var restored: [String] = []
            for row in rows {
                let id: String = row["id"]
                let isAvailable: Bool = row["isAvailable"]
                let shouldBeAvailable = activeIDs.contains(id)
                if isAvailable && !shouldBeAvailable { missing.append(id) }
                else if !isAvailable && shouldBeAvailable { restored.append(id) }
            }
            // Progressive imports already saved available tracks. Only changed availability needs a write.
            for (availability, ids) in [(0, missing), (1, restored)] {
                for offset in stride(from: 0, to: ids.count, by: 400) {
                    let chunk = Array(ids[offset..<min(offset + 400, ids.count)])
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    try db.execute(sql: "UPDATE tracks SET isAvailable = \(availability) WHERE sourceID = ? AND id IN (\(placeholders))",
                                   arguments: StatementArguments([sourceID] + chunk))
                }
            }
            return !missing.isEmpty || !restored.isEmpty
        }
    }

    @discardableResult
    public func reconcileTracks(sourceID: String, activeIDs: [String]) throws -> Bool {
        try reconcileTracks(sourceID: sourceID, activeIDs: Set(activeIDs))
    }

    public func updateTrackMetadata(_ track: TrackRecord) throws {
        try database.write { db in
            var updated = track
            if let existing = try TrackRecord.fetchOne(db, key: track.id) {
                updated.addedAt = existing.addedAt
                updated.lastPlayedAt = existing.lastPlayedAt
                updated.playCount = existing.playCount
                updated.rating = existing.rating
            }
            updated.metadataLocked = true
            if let previous = try TrackRecord.fetchOne(db, key: track.id),
               updated.albumID == previous.albumID,
               previous.album != updated.album || previous.albumArtist != updated.albumArtist {
                updated.albumID = StableID.make(updated.sourceID, updated.albumArtist, updated.album, previous.albumID)
            }
            try updated.save(db)
        }
    }

    public func setMetadataLocked(trackID: String, locked: Bool) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE tracks SET metadataLocked = ? WHERE id = ?", arguments: [locked, trackID])
        }
    }

    public func setRating(trackID: String, rating: Int) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE tracks SET rating = ? WHERE id = ?", arguments: [min(5, max(0, rating)), trackID])
        }
    }

    public func recordPlay(trackID: String, at date: Date = Date()) throws {
        try database.write { db in
            guard try TrackRecord.fetchOne(db, key: trackID) != nil else { throw LibraryStoreError.trackNotFound(trackID) }
            try db.execute(sql: "UPDATE tracks SET playCount = playCount + 1, lastPlayedAt = ? WHERE id = ?", arguments: [date, trackID])
            try db.execute(sql: "INSERT INTO listeningHistory(id, trackID, playedAt) VALUES (?, ?, ?)", arguments: [UUID().uuidString, trackID, date])
        }
    }

    public func recentlyAdded(sourceID: String, limit: Int = 20) throws -> [TrackRecord] {
        Array(try tracks(sourceID: sourceID).sorted { $0.addedAt > $1.addedAt }.prefix(max(0, limit)))
    }

    public func recentlyPlayed(sourceID: String, limit: Int = 20) throws -> [TrackRecord] {
        Array(try tracks(sourceID: sourceID).filter { $0.lastPlayedAt != nil }
            .sorted { $0.lastPlayedAt! > $1.lastPlayedAt! }.prefix(max(0, limit)))
    }

    public func mostPlayed(sourceID: String, limit: Int = 20) throws -> [TrackRecord] {
        Array(try tracks(sourceID: sourceID).filter { $0.playCount > 0 }
            .sorted { $0.playCount == $1.playCount ? TrackRecord.libraryOrder($0, $1) : $0.playCount > $1.playCount }
            .prefix(max(0, limit)))
    }

    public func playlists() throws -> [PlaylistRecord] {
        try database.read { try PlaylistRecord.fetchAll($0, sql: "SELECT * FROM playlists ORDER BY updatedAt DESC, name COLLATE NOCASE") }
    }

    @discardableResult
    public func savePlaylist(name: String, trackIDs: [String], id: String = UUID().uuidString) throws -> PlaylistRecord {
        try database.write { db in
            let existing = try PlaylistRecord.fetchOne(db, key: id)
            let playlist = PlaylistRecord(id: id, name: name, createdAt: existing?.createdAt ?? Date(), updatedAt: Date())
            try playlist.save(db)
            try db.execute(sql: "DELETE FROM playlistEntries WHERE playlistID = ?", arguments: [id])
            for (position, trackID) in trackIDs.enumerated() {
                guard try TrackRecord.fetchOne(db, key: trackID) != nil else { continue }
                try db.execute(sql: "INSERT INTO playlistEntries(playlistID, trackID, position) VALUES (?, ?, ?)", arguments: [id, trackID, position])
            }
            return playlist
        }
    }

    public func playlistTracks(id: String) throws -> [TrackRecord] {
        try database.read { db in
            try TrackRecord.fetchAll(db, sql: """
                SELECT tracks.* FROM tracks JOIN playlistEntries ON tracks.id = playlistEntries.trackID
                WHERE playlistEntries.playlistID = ? ORDER BY playlistEntries.position
                """, arguments: [id])
        }
    }

    public func deletePlaylist(id: String) throws {
        try database.write { try $0.execute(sql: "DELETE FROM playlists WHERE id = ?", arguments: [id]) }
    }

    public func saveQueue(trackIDs: [String], currentIndex: Int, position: Double) throws {
        let snapshot = PlaybackQueueSnapshot(trackIDs: trackIDs, currentIndex: currentIndex, position: position)
        let data = try JSONEncoder().encode(snapshot)
        try database.write { db in
            try db.execute(sql: "INSERT INTO appState(key, value) VALUES ('playbackQueue', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [data])
            try db.execute(sql: "DELETE FROM appState WHERE key = 'playbackResume'")
        }
    }

    /// Frequent resume checkpoints never re-encode the potentially large list of queued track IDs.
    public func saveQueuePosition(currentIndex: Int, position: Double) throws {
        let checkpoint = QueueResumeCheckpoint(currentIndex: max(0, currentIndex), position: position.isFinite ? max(0, position) : 0)
        try setValue(JSONEncoder().encode(checkpoint), forKey: "playbackResume")
    }

    public func loadQueue() throws -> PlaybackQueueSnapshot? {
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM appState WHERE key = 'playbackQueue'") else { return nil }
            var snapshot = try JSONDecoder().decode(PlaybackQueueSnapshot.self, from: data)
            if let position = try Data.fetchOne(db, sql: "SELECT value FROM appState WHERE key = 'playbackResume'"),
               let resume = try? JSONDecoder().decode(QueueResumeCheckpoint.self, from: position) {
                snapshot.currentIndex = snapshot.trackIDs.isEmpty ? 0 : min(max(0, resume.currentIndex), snapshot.trackIDs.count - 1)
                snapshot.position = resume.position
            }
            return snapshot
        }
    }

    public func setValue(_ data: Data?, forKey key: String) throws {
        try database.write { db in
            if let data {
                try db.execute(sql: "INSERT INTO appState(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, data])
            } else {
                try db.execute(sql: "DELETE FROM appState WHERE key = ?", arguments: [key])
            }
        }
    }

    public func value(forKey key: String) throws -> Data? {
        try database.read { try Data.fetchOne($0, sql: "SELECT value FROM appState WHERE key = ?", arguments: [key]) }
    }

    @discardableResult
    static func saveIndexedTrack(_ incoming: TrackRecord, db: Database) throws -> Bool {
        let previous = try TrackRecord.fetchOne(db, key: incoming.id)
        let saved = try saveIndexedTrack(incoming, preserving: previous, db: db)
        return previous != saved
    }

    @discardableResult
    private static func saveIndexedTrack(_ incoming: TrackRecord, preserving previous: TrackRecord?, db: Database) throws -> TrackRecord {
        var track = incoming
        if let previous {
            track.addedAt = previous.addedAt
            track.playCount = previous.playCount
            track.lastPlayedAt = previous.lastPlayedAt
            track.rating = previous.rating
            track.metadataLocked = previous.metadataLocked
            if incoming.artworkPath == nil, incoming.remoteID != nil,
               incoming.remoteID == previous.remoteID, incoming.coverArtID == previous.coverArtID {
                track.artworkPath = previous.artworkPath
            }
            if previous.metadataLocked {
                track.title = previous.title
                track.artist = previous.artist
                track.albumArtist = previous.albumArtist
                track.album = previous.album
                track.albumID = previous.albumID
                track.year = previous.year
                track.genre = previous.genre
                track.trackNumber = previous.trackNumber
                track.discNumber = previous.discNumber
                track.artworkPath = previous.artworkPath ?? incoming.artworkPath
            }
        }
        if let previous {
            // Update only changed columns. Artwork/statistics/availability changes do not rebuild FTS.
            _ = try track.updateChanges(db, from: previous)
        } else { try track.insert(db) }
        return track
    }

    private static func searchPattern(_ query: String) -> String? {
        let tokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.prefix(20).map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " AND ")
    }
}
