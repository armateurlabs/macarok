import MacarokCore
import XCTest
@testable import MacarokApp

@MainActor
final class SharingTests: XCTestCase {
    func testSharedTextUsesKnownSongLinksAndEpisodePages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokSharing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let music = SourceRecord(id: "music", kind: .local, name: "Music", location: root.absoluteString)
        let song = TrackRecord(id: "song", sourceID: music.id, title: "Alors on danse (Radio Edit)", artist: "Stromae", album: "Cheese")
        let show = SourceRecord(id: "show", kind: .podcasts, name: "Show", location: "https://example.org/feed.xml")
        let episode = TrackRecord(id: "episode", sourceID: show.id, title: "Episode 1", artist: "Host", album: "The Show",
                                  fileURL: "https://example.org/episode-1.mp3")
        try store.saveSource(music, tracks: [song])
        try store.saveSource(show, tracks: [episode])
        let key = try XCTUnwrap(SongKey(track: song))
        try store.saveSongWikipedia(URL(string: "https://en.wikipedia.org/wiki/Alors_on_danse"), for: key)
        try store.saveSongVideo(YouTubeVideo(id: "SXoQHp2cQQc", title: "Alors On Danse", channel: "Stromae", origin: .musicBrainz), for: key)
        let model = AppModel(store: store, registerSystemControls: false)
        await model.start()

        let songText = await model.shareText(for: song)
        XCTAssertEqual(songText, "Alors on danse (Radio Edit) — Stromae\nhttps://en.wikipedia.org/wiki/Alors_on_danse\nhttps://www.youtube.com/watch?v=SXoQHp2cQQc")
        let episodeText = await model.shareText(for: episode)
        XCTAssertEqual(episodeText, "The Show — Episode 1\nhttps://example.org/episode-1.mp3", "Without an episode page, the episode's own address is shared.")
        await model.finishPlaybackAccess()
    }

    func testYouTubePlayerEventsAndInlinePages() {
        XCTAssertEqual(YouTubeWeb.playerEvent(["event": "state", "value": 1]), .playing)
        XCTAssertEqual(YouTubeWeb.playerEvent(["event": "state", "value": 2]), .stopped)
        for code in [101, 150, 153] { XCTAssertEqual(YouTubeWeb.playerEvent(["event": "error", "value": code]), .refused, "\(code)") }
        XCTAssertEqual(YouTubeWeb.playerEvent(["event": "error", "value": 100]), .missing)
        XCTAssertNil(YouTubeWeb.playerEvent(["event": "state", "value": 3]))
        XCTAssertTrue(YouTubeWeb.staysInline(URL(string: "https://www.youtube.com/results?search_query=x")))
        XCTAssertTrue(YouTubeWeb.staysInline(URL(string: "https://consent.youtube.com/m?continue=x")))
        XCTAssertFalse(YouTubeWeb.staysInline(URL(string: "https://example.com")))
        XCTAssertFalse(YouTubeWeb.staysInline(URL(string: "http://www.youtube.com")))
    }
}
