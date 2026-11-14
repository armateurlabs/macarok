import XCTest
import Foundation
@testable import MacarokCore

final class PodcastAndPlaylistTests: XCTestCase {
    func testRSSPodcastParsesEnclosuresArtworkDurationAndStableIdentifiers() throws {
        let xml = """
        <?xml version="1.0"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
        <title>Listening Room</title><itunes:author>Alex &amp; Jo</itunes:author><itunes:image href="/cover.jpg"/>
        <item><guid>episode-1</guid><title>First episode</title><description><![CDATA[<p>Inside the music.</p>]]></description>
        <enclosure url="https://audio.example/first.mp3?token=abc&amp;download=1" type="audio/mpeg"/>
        <itunes:duration>01:02:03</itunes:duration><itunes:episode>4</itunes:episode><itunes:season>2</itunes:season>
        <pubDate>Fri, 13 Nov 2026 10:30:00 +0000</pubDate></item>
        <item><guid>episode-1</guid><title>Duplicate</title><enclosure url="https://audio.example/duplicate.mp3" type="audio/mpeg"/></item>
        <item><title>No audio</title><link>https://example.org/page</link></item>
        </channel></rss>
        """
        let feed = try PodcastClient.parse(data: Data(xml.utf8), sourceURL: URL(string: "https://podcasts.example/feed.xml")!)
        XCTAssertEqual(feed.title, "Listening Room")
        XCTAssertEqual(feed.author, "Alex & Jo")
        XCTAssertEqual(feed.artworkURL?.absoluteString, "https://podcasts.example/cover.jpg")
        XCTAssertEqual(feed.episodes.count, 1)
        XCTAssertEqual(feed.episodes[0].duration, 3723)
        XCTAssertEqual(feed.episodes[0].description, "Inside the music.")
        XCTAssertNotNil(feed.episodes[0].publicationDate)
        XCTAssertEqual(feed.episodes[0].audioURL.query, "token=abc&download=1")
        let track = feed.episodes[0].asTrackRecord(sourceID: "feed-1", feed: feed)
        XCTAssertEqual(track.album, "Listening Room")
        XCTAssertEqual(track.discNumber, 2)
        XCTAssertEqual(track.trackNumber, 4)
        XCTAssertEqual(track.year, 2026)
        XCTAssertEqual(track.id, feed.episodes[0].asTrackRecord(sourceID: "feed-1", feed: feed).id)
    }

    func testAtomPodcastResolvesRelativeAudioAndISODate() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>An Atom Show</title><author><name>Someone</name></author>
        <entry><id>urn:episode:2</id><title>Second</title><published>2026-11-14T11:00:00Z</published><link rel="enclosure" type="audio/ogg" href="episodes/2.ogg"/></entry></feed>
        """
        let feed = try PodcastClient.parse(data: Data(xml.utf8), sourceURL: URL(string: "https://example.org/podcast/feed.atom")!)
        XCTAssertEqual(feed.author, "Someone")
        XCTAssertEqual(feed.episodes.first?.audioURL.absoluteString, "https://example.org/podcast/episodes/2.ogg")
        XCTAssertNotNil(feed.episodes.first?.publicationDate)
    }

    func testInvalidPodcastIsRejected() {
        XCTAssertThrowsError(try PodcastClient.parse(data: Data("<html><title>Website</title></html>".utf8), sourceURL: URL(string: "https://example.org")!))
    }

    func testPodcastKeepsPrivateEnclosureQueryButRejectsURLUserInfo() throws {
        let xml = """
        <rss version="2.0"><channel><title>Private Feed</title>
        <item><guid>safe</guid><enclosure url="https://audio.example/episode.mp3?token=private" type="audio/mpeg"/></item>
        <item><guid>userinfo</guid><enclosure url="https://user:password@audio.example/episode.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """
        let feed = try PodcastClient.parse(data: Data(xml.utf8), sourceURL: URL(string: "https://podcasts.example/feed?token=feed-token")!)
        XCTAssertEqual(feed.url.query, "token=feed-token")
        XCTAssertEqual(feed.episodes.map(\.id), ["safe"])
        XCTAssertEqual(feed.episodes.first?.audioURL.query, "token=private")
    }

    func testM3UPreservesCueSegmentsAndRelativeUnicodePaths() throws {
        let playlist = URL(fileURLWithPath: "/Music/Playlists/evening.m3u8")
        let audio = URL(fileURLWithPath: "/Music/Albums/Échos/album.flac")
        let entries = [PlaylistEntry(url: audio, title: "Artist, Title", duration: 220, startTime: 60.2, endTime: 280.2, trackID: "track-1", sourceID: "local-1"),
                       PlaylistEntry(url: audio, title: "Next", duration: 120, startTime: 280.2, endTime: 400.2, trackID: "track-2", sourceID: "local-1")]
        let text = try PlaylistIO.serialize(entries: entries, relativeTo: playlist)
        XCTAssertTrue(text.contains("../Albums/Échos/album.flac"))
        XCTAssertTrue(text.contains("#EXTVLCOPT:start-time=60.2"))
        let parsed = PlaylistIO.parse(text: text, playlistURL: playlist)
        XCTAssertEqual(parsed, entries)
    }

    func testPLSImportsEntriesInNumericOrderAndPreservesURLQueries() throws {
        let text = """
        [playlist]
        File2=https://example.org/stream?x=1&y=2
        Title2=Radio
        Length2=-1
        File1=../Albums/first.mp3
        Title1=First
        Length1=123
        NumberOfEntries=2
        Version=2
        """
        let entries = PlaylistIO.parse(text: text, playlistURL: URL(fileURLWithPath: "/Music/Playlists/test.pls"))
        XCTAssertEqual(entries.map(\.title), ["First", "Radio"])
        XCTAssertEqual(entries[0].url.path, "/Music/Albums/first.mp3")
        XCTAssertEqual(entries[1].url.query, "x=1&y=2")
        XCTAssertNil(entries[1].duration)
        XCTAssertThrowsError(try PlaylistIO.serialize(entries: [.init(url: entries[0].url, startTime: 10)], format: .pls))
    }

    func testCleanupPreservesIntentionalCapitalizationAndUnknownData() {
        let track = TrackRecord(sourceID: "local", title: "  a\tTitle\n ", artist: "iTunes Artist", album: "My Album", genre: "Electronic")
        let proposal = MetadataCleanup.proposal(for: track)
        XCTAssertEqual(proposal.changes.map(\.field), ["title"])
        let changed = proposal.applying(to: track)
        XCTAssertEqual(changed.title, "a Title")
        XCTAssertEqual(changed.artist, "iTunes Artist")
        XCTAssertEqual(changed.id, track.id)
    }
}
