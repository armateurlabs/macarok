import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

@MainActor
final class WikipediaPaneTests: XCTestCase {
    func testSearchMetadataIsEncodedAsOneQueryValueWithoutChangingTheDestination() throws {
        let text = "  AC/DC & Björk #1?title=Other\n page + 夢  "
        let url = try XCTUnwrap(WikipediaLookup.searchURL(for: text))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "en.wikipedia.org")
        XCTAssertEqual(components.path, "/w/index.php")
        XCTAssertNil(components.fragment)
        XCTAssertNil(components.user)
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["search"], "AC/DC & Björk #1?title=Other page + 夢")
        XCTAssertEqual(items["title"], "Special:Search")
        XCTAssertEqual(items["go"], "Go")
        XCTAssertEqual(items["useskin"], "minerva")
        XCTAssertNil(WikipediaLookup.searchURL(for: " \n\t "))
    }

    func testArtistAndAlbumLookupsUseTheirOwnMetadataAndHandleMissingTags() {
        let track = TrackRecord(id: "wiki", sourceID: "source", title: "A track", artist: "Track Artist", albumArtist: "Album Artist", album: "The Album")
        XCTAssertEqual(WikipediaLookup.query(for: track, topic: .artist), "Track Artist")
        XCTAssertEqual(WikipediaLookup.query(for: track, topic: .album), "The Album Album Artist album")
        var missing = track
        missing.artist = " Unknown Artist "
        XCTAssertEqual(WikipediaLookup.query(for: missing, topic: .artist), "Album Artist")
        missing.albumArtist = ""
        missing.album = "Unknown Album"
        XCTAssertNil(WikipediaLookup.query(for: missing, topic: .artist))
        XCTAssertNil(WikipediaLookup.query(for: missing, topic: .album))
        XCTAssertNil(WikipediaLookup.query(for: nil, topic: .artist))
    }

    func testNavigationAllowsEnglishWikipediaAndRequiresAUserClickForExternalWebLinks() {
        for text in ["https://en.wikipedia.org/wiki/Artist", "https://en.m.wikipedia.org/wiki/Album", "http://en.wikipedia.org/wiki/Artist"] {
            XCTAssertEqual(WikipediaLookup.navigation(for: URL(string: text), userInitiated: false), .inline)
        }
        for text in ["https://example.com", "https://fr.wikipedia.org/wiki/Artiste", "https://en.wikipedia.org.evil.invalid/wiki/Artist"] {
            XCTAssertEqual(WikipediaLookup.navigation(for: URL(string: text), userInitiated: false), .cancel)
            XCTAssertEqual(WikipediaLookup.navigation(for: URL(string: text), userInitiated: true), .external)
        }
        for text in ["file:///private/music.mp3", "javascript:alert(1)", "mailto:user@example.com", "https://user:password@en.wikipedia.org/wiki/Artist"] {
            XCTAssertEqual(WikipediaLookup.navigation(for: URL(string: text), userInitiated: true), .cancel)
        }
        XCTAssertEqual(WikipediaLookup.navigation(for: nil, userInitiated: true), .cancel)
    }

    func testNewTargetsAndHiddenViewsCancelRequestsAndRejectObsoleteCallbacks() throws {
        let session = WikipediaBrowserSession()
        var cancellations = 0
        session.bind(owner: UUID()) { cancellations += 1 }
        let a = try XCTUnwrap(WikipediaLookup.searchURL(for: "First Artist"))
        let b = try XCTUnwrap(WikipediaLookup.searchURL(for: "Second Artist"))
        session.show(a)
        let first = session.generation
        session.show(b)
        let second = session.generation
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(cancellations, 2)
        session.finished(generation: first, url: a)
        session.failed(generation: first, message: "An obsolete request failed")
        XCTAssertEqual(session.state, .loading)
        XCTAssertEqual(session.displayURL, b)
        session.finished(generation: second, url: b)
        XCTAssertEqual(session.state, .loaded)
        session.show(b)
        XCTAssertEqual(session.generation, second, "The same artist/album page must not reload on every track change.")
        session.show(b, force: true)
        let retry = session.generation
        XCTAssertNotEqual(retry, second)
        session.hide()
        XCTAssertFalse(session.isVisible)
        XCTAssertNil(session.requestedURL)
        session.finished(generation: retry, url: b)
        session.failed(generation: retry, message: "Late callback after leaving Wikipedia")
        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.displayURL)
        XCTAssertEqual(cancellations, 4)
    }

    func testOldNativeViewCannotDetachTheReplacementViewCancellation() throws {
        let session = WikipediaBrowserSession()
        let first = UUID(), replacement = UUID()
        var firstCalls = 0, replacementCalls = 0
        session.bind(owner: first) { firstCalls += 1 }
        session.bind(owner: replacement) { replacementCalls += 1 }
        session.unbind(owner: first)
        session.show(try XCTUnwrap(WikipediaLookup.searchURL(for: "Artist")))
        XCTAssertEqual(firstCalls, 0)
        XCTAssertEqual(replacementCalls, 1)
        session.hide()
        XCTAssertEqual(replacementCalls, 2)
    }

    func testWikipediaFollowsPlaybackWithAnInactiveDraftAndRespectsAPresentedArtworkPin() throws {
        let model = AppModel(preferences: AppPreferences(), registerSystemControls: false)
        let first = QueueItem(track: TrackRecord(id: "wiki-first", sourceID: "source", title: "First", artist: "First Artist", album: "First Album"))
        let next = QueueItem(track: TrackRecord(id: "wiki-next", sourceID: "source", title: "Next", artist: "Next Artist", album: "Next Album"))
        model.queue = [first, next]; model.currentQueueID = first.id; model.centerPage = .playing
        model.beginMetadataEditing(first.track)
        let session = try XCTUnwrap(model.metadataEditingSession)
        session.draft.title = "Unfinished correction"
        model.contextMode = .wikipedia
        model.currentQueueID = next.id
        XCTAssertEqual(WikipediaLookup.query(for: model.playingContextTrack, topic: .artist), "Next Artist")
        XCTAssertTrue(model.metadataEditingSession === session)
        XCTAssertEqual(session.draft.title, "Unfinished correction")
        model.artworkTrack = first.track
        XCTAssertEqual(WikipediaLookup.query(for: model.playingContextTrack, topic: .artist), "First Artist")
        model.finishMetadataEditing(sessionID: session.id)
        XCTAssertEqual(model.contextMode, .wikipedia)
        XCTAssertEqual(WikipediaLookup.query(for: model.playingContextTrack, topic: .artist), "First Artist")
        model.artworkTrack = nil
        XCTAssertEqual(WikipediaLookup.query(for: model.playingContextTrack, topic: .artist), "Next Artist")
    }
}
