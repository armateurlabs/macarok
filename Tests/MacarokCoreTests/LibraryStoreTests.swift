import Foundation
import GRDB
import XCTest
@testable import MacarokCore

final class LibraryStoreTests: XCTestCase {
    func testSearchIsIsolatedBySourceAndToleratesPunctuation() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(url: folder.appendingPathComponent("test.sqlite"))
        let local = SourceRecord(kind: .local, name: "Local", location: folder.path)
        let server = SourceRecord(kind: .openSubsonic, name: "Server", location: "https://music.example")
        try store.saveSource(local)
        try store.saveSource(server)
        try store.upsertTracks([
            TrackRecord(id: "local", sourceID: local.id, title: "Jóga", artist: "Björk", album: "Homogenic"),
            TrackRecord(id: "server", sourceID: server.id, title: "Jóga", artist: "Björk", album: "Homogenic")
        ])
        XCTAssertEqual(try store.tracks(sourceID: local.id, query: "bjork jog").map(\.id), ["local"])
        XCTAssertEqual(try store.tracks(sourceID: server.id, query: "Jóga \" OR *").count, 0)
        XCTAssertEqual(try store.tracks(sourceID: local.id, query: "\"*() :").map(\.id), ["local"])
    }

    func testReindexPreservesHistoryRatingsCorrectionsAndPlaylistDuplicates() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(url: folder.appendingPathComponent("test.sqlite"))
        let source = SourceRecord(kind: .local, name: "Music", location: folder.path)
        try store.saveSource(source)
        let oldDate = Date(timeIntervalSince1970: 1_000)
        var track = TrackRecord(id: "one", sourceID: source.id, title: "Original", artist: "Artist", album: "Album", addedAt: oldDate)
        try store.upsertTracks([track])
        try store.recordPlay(trackID: track.id, at: oldDate)
        try store.setRating(trackID: track.id, rating: 4)
        track.title = "My corrected title"
        try store.updateTrackMetadata(track)
        let playlist = try store.savePlaylist(name: "Twice", trackIDs: [track.id, track.id])
        track.title = "Changed by another tool"
        track.addedAt = Date()
        try store.upsertTracks([track])
        let reindexed = try XCTUnwrap(store.track(id: track.id))
        XCTAssertEqual(reindexed.title, "My corrected title")
        XCTAssertEqual(reindexed.playCount, 1)
        XCTAssertEqual(reindexed.rating, 4)
        XCTAssertEqual(reindexed.addedAt, oldDate)
        XCTAssertEqual(reindexed.lastPlayedAt, oldDate)
        XCTAssertEqual(try store.playlistTracks(id: playlist.id).map(\.id), [track.id, track.id])

        try store.reconcileTracks(sourceID: source.id, activeIDs: Set<String>())
        XCTAssertEqual(try store.tracks(sourceID: source.id).count, 0)
        XCTAssertFalse(try XCTUnwrap(store.track(id: track.id)).isAvailable)
        XCTAssertEqual(try store.playlistTracks(id: playlist.id).count, 2)
        try store.upsertTracks([track])
        XCTAssertEqual(try store.tracks(sourceID: source.id).count, 1)
    }

    func testQueueAndRemoteMetadataSurviveReopeningDatabase() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        let source = SourceRecord(kind: .openSubsonic, name: "Server", location: "https://music.example")
        do {
            let store = try LibraryStore(url: url)
            try store.saveSource(source)
            try store.upsertTracks([TrackRecord(id: "one", sourceID: source.id, remoteID: "remote-1", remotePath: "Artist/Album/01.flac", coverArtID: "cover-1")])
            try store.saveQueue(trackIDs: ["one", "one"], currentIndex: 1, position: 45.5)
        }
        let reopened = try LibraryStore(url: url)
        XCTAssertEqual(try reopened.loadQueue(), PlaybackQueueSnapshot(trackIDs: ["one", "one"], currentIndex: 1, position: 45.5))
        let track = try XCTUnwrap(reopened.track(id: "one"))
        XCTAssertEqual(track.remotePath, "Artist/Album/01.flac")
        XCTAssertEqual(track.coverArtID, "cover-1")
    }

    func testTrackIdentityIncludesSourceAndHandlesDelimiterCollisions() {
        XCTAssertNotEqual(StableID.make("source-a", "song"), StableID.make("source-b", "song"))
        XCTAssertNotEqual(StableID.make("ab", "c"), StableID.make("a", "bc"))
        XCTAssertEqual(StableID.make("source", "song"), StableID.make("source", "song"))
    }

    func testMetadataEditPreservesExplicitCanonicalAlbumIdentityAcrossRescan() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(url: folder.appendingPathComponent("test.sqlite"))
        let source = SourceRecord(kind: .local, name: "Music", location: folder.path)
        try store.saveSource(source)
        let original = TrackRecord(id: "one", sourceID: source.id, albumID: "original-album", title: "Song", artist: "Artist", album: "Original")
        try store.upsertTracks([original])
        try store.recordPlay(trackID: original.id)
        let playlist = try store.savePlaylist(name: "Saved", trackIDs: [original.id])
        var edited = original
        edited.album = "Corrected"
        edited.albumID = StableID.make(source.id, edited.albumArtist, edited.album, "Artist/Album")
        try store.updateTrackMetadata(edited)
        XCTAssertEqual(try store.track(id: edited.id)?.albumID, edited.albumID)

        try store.setMetadataLocked(trackID: edited.id, locked: false)
        try store.upsertTracks([edited])
        XCTAssertEqual(try store.albums(sourceID: source.id).map(\.id), [edited.albumID])
        XCTAssertEqual(try store.track(id: edited.id)?.playCount, 1)
        XCTAssertEqual(try store.playlistTracks(id: playlist.id).map(\.id), [edited.id])
    }

    func testReconciliationWritesOnlyAvailabilityChangesAndPreservesSourceUserData() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(url: folder.appendingPathComponent("test.sqlite"))
        let source = SourceRecord(id: "server", kind: .openSubsonic, name: "Server", location: "https://music.example")
        let other = SourceRecord(id: "other", kind: .openSubsonic, name: "Other", location: "https://other.example")
        try store.saveSource(source)
        try store.saveSource(other)
        let playedAt = Date(timeIntervalSince1970: 1_000)
        try store.upsertTracks([
            TrackRecord(id: "unchanged", sourceID: source.id, title: "Keep title", artist: "Keep artist", genre: "Keep genre"),
            TrackRecord(id: "missing", sourceID: source.id, title: "Saved track"),
            TrackRecord(id: "restored", sourceID: source.id, isAvailable: false),
            TrackRecord(id: "still-missing", sourceID: source.id, isAvailable: false),
            TrackRecord(id: "other-source", sourceID: other.id)
        ])
        try store.recordPlay(trackID: "missing", at: playedAt)
        try store.setRating(trackID: "missing", rating: 4)
        let playlist = try store.savePlaylist(name: "Preserve missing", trackIDs: ["missing", "missing"])
        try store.database.write { db in
            try db.execute(sql: """
                CREATE TABLE availabilityAudit (trackID TEXT NOT NULL);
                CREATE TRIGGER auditAvailability AFTER UPDATE OF isAvailable ON tracks BEGIN
                    INSERT INTO availabilityAudit(trackID) VALUES (new.id);
                END;
                """)
        }

        let active: Set<String> = ["unchanged", "restored", "unknown", "other-source"]
        try store.reconcileTracks(sourceID: source.id, activeIDs: active)

        let writes = try store.database.read { try String.fetchAll($0, sql: "SELECT trackID FROM availabilityAudit ORDER BY trackID") }
        XCTAssertEqual(writes, ["missing", "restored"], "Unchanged rows and another source must not be rewritten.")
        XCTAssertEqual(Set(try store.tracks(sourceID: source.id).map(\.id)), ["unchanged", "restored"])
        XCTAssertEqual(try store.tracks(sourceID: other.id).map(\.id), ["other-source"])
        let missing = try XCTUnwrap(store.track(id: "missing"))
        XCTAssertEqual(missing.title, "Saved track")
        XCTAssertEqual(missing.playCount, 1)
        XCTAssertEqual(missing.lastPlayedAt, playedAt)
        XCTAssertEqual(missing.rating, 4)
        XCTAssertEqual(try store.playlistTracks(id: playlist.id).map(\.id), ["missing", "missing"])
        let unchanged = try XCTUnwrap(store.track(id: "unchanged"))
        XCTAssertEqual(unchanged.artist, "Keep artist")
        XCTAssertEqual(unchanged.genre, "Keep genre")

        try store.reconcileTracks(sourceID: source.id, activeIDs: active)
        let repeatedWrites = try store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM availabilityAudit") }
        XCTAssertEqual(repeatedWrites, 2, "An unchanged successful import must not update availability again.")
    }

    func testRemoteArtworkCacheSurvivesUnchangedCoverAndInvalidatesChangedCover() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(url: folder.appendingPathComponent("test.sqlite"))
        let source = SourceRecord(kind: .openSubsonic, name: "Server", location: "https://music.example")
        try store.saveSource(source)
        var track = TrackRecord(id: "remote", sourceID: source.id, title: "Original", remoteID: "song-1",
                                coverArtID: "cover-1", artworkPath: "/cache/cover-1.image")
        try store.upsertTracks([track])

        track.title = "Updated server title"
        track.artworkPath = nil
        try store.upsertTracks([track])
        XCTAssertEqual(try store.track(id: track.id)?.title, "Updated server title")
        XCTAssertEqual(try store.track(id: track.id)?.artworkPath, "/cache/cover-1.image")
        XCTAssertEqual(try store.track(id: track.id)?.metadataLocked, false)

        track.coverArtID = "cover-2"
        try store.upsertTracks([track])
        XCTAssertNil(try store.track(id: track.id)?.artworkPath, "A different cover identifier must invalidate an unlocked cached image.")
    }

    func testArtworkRefreshPreservesLockedRemoteOverlayButClearsRemovedLocalArtwork() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(url: folder.appendingPathComponent("test.sqlite"))
        let remote = SourceRecord(kind: .openSubsonic, name: "Server", location: "https://music.example")
        let local = SourceRecord(kind: .local, name: "Local", location: folder.absoluteString)
        try store.saveSource(remote)
        try store.saveSource(local)
        var remoteTrack = TrackRecord(id: "remote", sourceID: remote.id, title: "My title", remoteID: "song-1",
                                      coverArtID: "cover-1", artworkPath: "/cache/my-cover.image")
        var localTrack = TrackRecord(id: "local", sourceID: local.id, artworkPath: "/cache/local-cover.image")
        try store.upsertTracks([remoteTrack, localTrack])
        try store.updateTrackMetadata(remoteTrack)

        remoteTrack.title = "Server title"
        remoteTrack.coverArtID = "cover-2"
        remoteTrack.artworkPath = nil
        localTrack.artworkPath = nil
        try store.upsertTracks([remoteTrack, localTrack])

        XCTAssertEqual(try store.track(id: remoteTrack.id)?.artworkPath, "/cache/my-cover.image")
        XCTAssertEqual(try store.track(id: remoteTrack.id)?.title, "My title")
        XCTAssertNil(try store.track(id: localTrack.id)?.artworkPath, "Removed local artwork must not be preserved just because its optional cover ID is still nil.")
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
