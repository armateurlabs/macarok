import Foundation
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

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
