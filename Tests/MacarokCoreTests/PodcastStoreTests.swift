import Foundation
import XCTest
@testable import MacarokCore

final class PodcastStoreTests: XCTestCase {
    func testParsesShowWebsiteSerialTypeAndEpisodeLinks() throws {
        let xml = """
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:atom="http://www.w3.org/2005/Atom"><channel>
        <title>Serial Show</title><link>https://show.example/</link><atom:link rel="self" href="https://show.example/feed.xml"/>
        <itunes:type>serial</itunes:type>
        <item><guid>1</guid><title>One</title><link>https://show.example/1</link><enclosure url="https://audio.example/1.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """
        let feed = try PodcastClient.parse(data: Data(xml.utf8), sourceURL: URL(string: "https://show.example/feed.xml")!)
        XCTAssertEqual(feed.link?.absoluteString, "https://show.example/")
        XCTAssertTrue(feed.isSerial)
        XCTAssertEqual(feed.episodes.first?.link?.absoluteString, "https://show.example/1")

        let atom = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Atom</title><link rel="alternate" href="https://atom.example/"/>
        <entry><id>a</id><title>A</title><link href="https://atom.example/a"/><link rel="enclosure" type="audio/mpeg" href="https://atom.example/a.mp3"/></entry></feed>
        """
        let atomFeed = try PodcastClient.parse(data: Data(atom.utf8), sourceURL: URL(string: "https://atom.example/feed")!)
        XCTAssertEqual(atomFeed.link?.absoluteString, "https://atom.example/")
        XCTAssertFalse(atomFeed.isSerial)
        XCTAssertEqual(atomFeed.episodes.first?.link?.absoluteString, "https://atom.example/a")
    }

    func testNotesKeepParagraphsLineBreaksListsAndEntities() {
        let html = """
        <p>Votre corps peut&nbsp;vieillir.
        Le Dr Addor est m&eacute;decin &amp; chercheur.</p><p><strong>DANS CET ÉPISODE :</strong><br>
        ▪️ Les tests<br/>▪️ Le sommeil</p><ul><li>00:00 Introduction</li><li>01:05 Les signes</li></ul>
        <p>Site : <a href="https://example.org/a?b=1&amp;c=2">example.org</a> &#8212; &#x2019;fin</p><!-- tracking -->
        """
        XCTAssertEqual(PodcastClient.plainText(fromHTML: html), """
        Votre corps peut vieillir. Le Dr Addor est médecin & chercheur.

        DANS CET ÉPISODE :
        ▪️ Les tests
        ▪️ Le sommeil

        • 00:00 Introduction
        • 01:05 Les signes

        Site : example.org — ’fin
        """)
        XCTAssertEqual(PodcastClient.plainText(fromHTML: "Line one\nLine two\n\n\n\nAfter   gap"), "Line one\nLine two\n\nAfter gap",
                       "Plain-text notes keep their own line breaks.")
    }

    func testConditionalFetchReturnsValidatorsThenNotModified() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConditionalFeedProtocol.self]
        let transport = SourceTransport(sourceID: "test.podcast.conditional", configuration: configuration)
        defer { transport.invalidate() }
        let client = PodcastClient(transport: transport)
        let url = URL(string: "https://conditional-feed.invalid/feed.xml")!

        guard case let .feed(feed, validators) = try await client.fetchFeed(url: url, validators: PodcastFeedValidators()) else {
            return XCTFail("The first request must return the feed.")
        }
        XCTAssertEqual(feed.title, "Conditional")
        XCTAssertEqual(validators, PodcastFeedValidators(etag: "\"v1\"", lastModified: "Tue, 17 Nov 2026 09:00:00 GMT"))
        let unchanged = try await client.fetchFeed(url: url, validators: validators)
        XCTAssertEqual(unchanged, .notModified)
        XCTAssertEqual(ConditionalFeedProtocol.lastIfNoneMatch, "\"v1\"")
    }

    func testFeedInfoNotesAndProgressPersistAndFollowTheirSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokPodcastStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let source = SourceRecord(id: "show", kind: .podcasts, name: "Show", location: "https://show.example/feed.xml")
        let episode = PodcastEpisode(id: "e1", title: "One", description: "Notes", audioURL: URL(string: "https://audio.example/1.mp3")!,
                                     link: URL(string: "https://show.example/1"))
        var feed = PodcastFeed(url: source.url!, title: "Show", author: "Host", description: "About the show", episodes: [episode],
                               link: URL(string: "https://show.example/"), isSerial: true)
        let track = episode.asTrackRecord(sourceID: source.id, feed: feed)
        try store.saveSource(source, tracks: [track])
        let refreshed = Date(timeIntervalSince1970: 1_800_000_000)
        try store.savePodcastFeed(sourceID: source.id, feed: feed, validators: PodcastFeedValidators(etag: "e"), now: refreshed)

        let show = try XCTUnwrap(store.podcastShows()[source.id])
        XCTAssertEqual(show.description, "About the show")
        XCTAssertEqual(show.link, "https://show.example/")
        XCTAssertTrue(show.isSerial)
        XCTAssertEqual(show.validators, PodcastFeedValidators(etag: "e"))
        XCTAssertEqual(show.refreshedAt, refreshed)
        XCTAssertEqual(try store.podcastNotes(trackID: track.id)?.notes, "Notes")

        try store.markPodcastRefresh(sourceID: source.id, error: "Offline")
        XCTAssertEqual(try store.podcastShows()[source.id]?.lastError, "Offline")
        XCTAssertEqual(try store.podcastShows()[source.id]?.refreshedAt, refreshed, "A failure keeps the last successful time.")

        feed.title = "Renamed"; feed.episodes[0].description = ""
        try store.savePodcastFeed(sourceID: source.id, feed: feed, validators: PodcastFeedValidators(), now: refreshed)
        XCTAssertEqual(try store.podcastShows()[source.id]?.title, "Renamed")
        XCTAssertNil(try store.podcastShows()[source.id]?.lastError)
        XCTAssertEqual(try store.podcastNotes(trackID: track.id)?.notes, "", "Episode notes follow the latest feed.")

        try store.savePodcastProgress([PodcastProgressRecord(trackID: track.id, sourceID: source.id, position: 120, duration: 600, isFinished: false)])
        XCTAssertEqual(try store.podcastProgress()[track.id]?.position, 120)

        try store.deleteSource(id: source.id)
        XCTAssertTrue(try store.podcastShows().isEmpty)
        XCTAssertTrue(try store.podcastProgress().isEmpty)
        XCTAssertNil(try store.podcastNotes(trackID: track.id))
    }
}

private final class ConditionalFeedProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var ifNoneMatch: String?
    static var lastIfNoneMatch: String? { lock.lock(); defer { lock.unlock() }; return ifNoneMatch }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "conditional-feed.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let tag = request.value(forHTTPHeaderField: "If-None-Match")
        Self.lock.lock(); Self.ifNoneMatch = tag; Self.lock.unlock()
        let unchanged = tag == "\"v1\""
        let response = HTTPURLResponse(url: request.url!, statusCode: unchanged ? 304 : 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "application/rss+xml", "ETag": "\"v1\"", "Last-Modified": "Tue, 17 Nov 2026 09:00:00 GMT",
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !unchanged {
            client?.urlProtocol(self, didLoad: Data("<rss version=\"2.0\"><channel><title>Conditional</title></channel></rss>".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
