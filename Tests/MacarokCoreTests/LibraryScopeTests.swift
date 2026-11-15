import Foundation
import GRDB
import XCTest
@testable import MacarokCore

final class LibraryScopeTests: XCTestCase {
    func testAllAndSourceScopesShareAvailabilityAndFullTextSearchRules() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokScopeStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("test.sqlite"))
        let a = SourceRecord(id: "a", kind: .local, name: "Local", location: directory.absoluteString)
        let b = SourceRecord(id: "b", kind: .openSubsonic, name: "Remote", location: "https://music.invalid")
        try store.saveSource(a); try store.saveSource(b)
        try store.upsertTracks([
            TrackRecord(id: "a-common", sourceID: a.id, title: "Common Song", artist: "Björk", album: "Album"),
            TrackRecord(id: "b-common", sourceID: b.id, title: "Common Song", artist: "Björk", album: "Album"),
            TrackRecord(id: "b-missing", sourceID: b.id, title: "Missing Common Song", artist: "Björk", album: "Album"),
            TrackRecord(id: "b-other", sourceID: b.id, title: "Other Song", artist: "Other Artist", album: "Other")
        ])
        try store.reconcileTracks(sourceID: b.id, activeIDs: ["b-common", "b-other"])
        XCTAssertEqual(Set(try store.tracks(scope: .all).map(\.id)), ["a-common", "b-common", "b-other"])
        XCTAssertEqual(Set(try store.tracks(scope: .all, query: "bjork common").map(\.id)), ["a-common", "b-common"])
        XCTAssertEqual(try store.tracks(scope: .source(a.id), query: "bjork common").map(\.id), ["a-common"])
        XCTAssertEqual(try store.tracks(scope: .source(b.id), query: "common").map(\.id), ["b-common"])
        XCTAssertEqual(try store.tracks(scope: .all, query: "\"*() :").count, 3)
        XCTAssertTrue(try store.tracks(scope: .source("missing")).isEmpty)
    }

    func testInitialSourceCatalogRollsBackAsOneTransactionWhenAnEpisodeFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokConnectionCommit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("test.sqlite"))
        try store.database.write { db in
            try db.execute(sql: "CREATE TRIGGER rejectEpisode BEFORE INSERT ON tracks WHEN NEW.id = 'bad' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
        }
        let source = SourceRecord(id: "podcast", kind: .podcasts, name: "Podcast", location: "https://podcast.invalid/feed")
        XCTAssertThrowsError(try store.saveSource(source, tracks: [TrackRecord(id: "good", sourceID: source.id), TrackRecord(id: "bad", sourceID: source.id)]))
        XCTAssertTrue(try store.sources().isEmpty)
        XCTAssertTrue(try store.allTracks().isEmpty)
        try store.saveSource(source, tracks: [TrackRecord(id: "good", sourceID: source.id)])
        XCTAssertEqual(try store.sources().map(\.id), [source.id])
        XCTAssertEqual(try store.tracks(sourceID: source.id).map(\.id), ["good"])
    }

    func testScopeRoundTripsWithoutOverloadingNoSourceSelection() throws {
        for scope in [LibraryScope.all, .source("source")] {
            XCTAssertEqual(try JSONDecoder().decode(LibraryScope.self, from: JSONEncoder().encode(scope)), scope)
        }
        XCTAssertTrue(LibraryScope.all.includes(sourceID: "any"))
        XCTAssertTrue(LibraryScope.source("source").includes(sourceID: "source"))
        XCTAssertFalse(LibraryScope.source("source").includes(sourceID: "another"))
        XCTAssertNil(LibraryScope.all.sourceID)
        XCTAssertEqual(LibraryScope.source("source").sourceID, "source")
    }

    func testAlbumPresentationIdentityIncludesSourceWithoutChangingCanonicalIdentity() {
        let a = AlbumRecord(tracks: [TrackRecord(id: "a", sourceID: "a", albumID: "album")])
        let b = AlbumRecord(tracks: [TrackRecord(id: "b", sourceID: "b", albumID: "album")])
        XCTAssertEqual(a.id, b.id)
        XCTAssertNotEqual(a.presentationID, b.presentationID)
    }
}
