import Foundation
import XCTest
@testable import MacarokCore

final class SongLinksTests: XCTestCase {
    func testSongKeyIgnoresEditionsGuestsAndAccents() throws {
        let plain = try XCTUnwrap(SongKey(artist: "Stromae", title: "Alors on danse"))
        XCTAssertEqual(SongKey(artist: "stromae feat. Kanye West", title: "Alors On Danse (Radio Edit)")?.id, plain.id)
        XCTAssertEqual(SongKey(artist: "Noir Desir", title: "Le vent nous portera - 2001 Remaster")?.id,
                       SongKey(artist: "Noir Désir", title: "Le Vent nous portera")?.id)
        XCTAssertEqual(SongKey(artist: "Muse", title: "Knights of Cydonia - Hyper Music")?.title, "Knights of Cydonia - Hyper Music",
                       "A dash that is part of the title stays.")
        XCTAssertNil(SongKey(artist: "Unknown Artist", title: "Song"))
        XCTAssertNil(SongKey(artist: "Artist", title: " "))
    }

    func testVideoIDsComeFromEveryYouTubeAddressForm() {
        let id = "SXoQHp2cQQc"
        for address in ["https://www.youtube.com/watch?v=\(id)&t=3", "https://youtu.be/\(id)", "https://music.youtube.com/watch?v=\(id)",
                        "https://www.youtube-nocookie.com/embed/\(id)", "https://m.youtube.com/shorts/\(id)"] {
            XCTAssertEqual(YouTubeVideo.videoID(from: URL(string: address)!), id, address)
        }
        XCTAssertNil(YouTubeVideo.videoID(from: URL(string: "https://www.youtube.com/results?search_query=x")!))
        XCTAssertNil(YouTubeVideo.videoID(from: URL(string: "https://example.com/watch?v=\(id)")!))
        XCTAssertNil(YouTubeVideo.videoID(from: URL(string: "https://www.youtube.com/watch?v=short")!))
    }

    func testLookupUsesMusicBrainzThenTheAPIKeyAndCachesResults() async throws {
        let store = try makeStore()
        let log = URLLog()
        let responses = Responses()
        let client = SongLinkClient(transport: { request in
            let url = request.url!.absoluteString
            await log.append(url)
            return await responses.answer(url)
        }, sleep: { _ in })
        let resolver = SongLinkResolver(store: store, client: client)
        let key = try XCTUnwrap(SongKey(artist: "Stromae", title: "Alors on danse"))

        let found = try await resolver.video(for: key, apiKey: nil)
        XCTAssertEqual(found.video, YouTubeVideo(id: "SXoQHp2cQQc", title: "Stromae - Alors On Danse", channel: "Stromae", origin: .musicBrainz))
        let requests = await log.urls.count
        _ = try await resolver.video(for: key, apiKey: nil)
        let afterCache = await log.urls.count
        XCTAssertEqual(afterCache, requests, "A known video is answered from the library database.")

        let other = try XCTUnwrap(SongKey(artist: "Radiohead", title: "Paranoid Android"))
        await responses.setMusicBrainzEmpty()
        let missing = try await resolver.video(for: other, apiKey: nil)
        XCTAssertNil(missing.video)
        let beforeRetry = await log.urls.count
        _ = try await resolver.video(for: other, apiKey: nil)
        let afterRetry = await log.urls.count
        XCTAssertEqual(afterRetry, beforeRetry, "A song without a video is not searched again for a week.")
        let searched = try await resolver.video(for: other, apiKey: "key")
        XCTAssertEqual(searched.video?.id, "6Qd0ZHlBfmg", "Adding an API key searches again.")
        XCTAssertEqual(searched.video?.title, "Radiohead - Paranoid Android's video")
        XCTAssertEqual(searched.alternatives.map(\.id), ["fHiGbolFFGw"])
        let lastURL = await log.urls.last
        XCTAssertTrue(lastURL?.contains("googleapis.com/youtube/v3/search") == true)
    }

    func testABusyMusicBrainzIsNotRememberedAsNotFound() async throws {
        let store = try makeStore()
        let log = URLLog()
        let client = SongLinkClient(transport: { request in
            await log.append(request.url!.absoluteString)
            return (Data(#"{"error":"busy"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }, sleep: { _ in })
        let resolver = SongLinkResolver(store: store, client: client)
        let key = try XCTUnwrap(SongKey(artist: "Artist", title: "Song"))
        let result = try await resolver.video(for: key, apiKey: nil)
        XCTAssertNil(result.video)
        XCTAssertNil(try store.songLinks(key).videoCheckedAt, "The next visit asks again.")
        let attempts = await log.urls.count
        XCTAssertEqual(attempts, 2, "One retry after MusicBrainz asks to slow down.")
    }

    func testAChosenVideoIsNeverReplacedByAnAutomaticMatch() throws {
        let store = try makeStore()
        let key = try XCTUnwrap(SongKey(artist: "Artist", title: "Song"))
        try store.saveSongVideo(YouTubeVideo(id: "chosenVid01", title: "Mine", channel: "", origin: .chosen), for: key)
        try store.saveSongVideo(YouTubeVideo(id: "automatic01", title: "Auto", channel: "", origin: .musicBrainz), for: key)
        XCTAssertEqual(try store.songLinks(key).video?.id, "chosenVid01")
        try store.forgetSongVideo(for: key)
        try store.saveSongVideo(YouTubeVideo(id: "automatic01", title: "Auto", channel: "", origin: .musicBrainz), for: key)
        XCTAssertEqual(try store.songLinks(key).video?.id, "automatic01")
    }

    func testWikipediaPrefersTheSongArticleThenTheArtist() throws {
        let pages = SongLinkClient.wikipediaPages(Data(#"""
        {"query":{"pages":[
          {"title":"Stromae","index":2,"fullurl":"https://en.wikipedia.org/wiki/Stromae","pageprops":{"wikibase-shortdesc":"Belgian musician and producer (born 1985)"}},
          {"title":"Alors on danse","index":1,"fullurl":"https://en.wikipedia.org/wiki/Alors_on_danse","pageprops":{"wikibase-shortdesc":"2009 single by Stromae"}},
          {"title":"Home (Depeche Mode song)","index":3,"fullurl":"https://en.wikipedia.org/wiki/Home_(Depeche_Mode_song)","pageprops":{"wikibase-shortdesc":"1997 single by Depeche Mode"}}
        ]}}
        """#.utf8))
        XCTAssertEqual(pages.map(\.title).first, "Alors on danse")
        let song = try XCTUnwrap(SongKey(artist: "Stromae", title: "Alors on danse"))
        XCTAssertEqual(SongLinkClient.songArticle(pages, key: song)?.lastPathComponent, "Alors_on_danse")
        XCTAssertEqual(SongLinkClient.songArticle(pages, key: try XCTUnwrap(SongKey(artist: "Depeche Mode", title: "Home")))?.lastPathComponent,
                       "Home_(Depeche_Mode_song)")
        let unknownSong = try XCTUnwrap(SongKey(artist: "Stromae", title: "Te quiero"))
        XCTAssertNil(SongLinkClient.songArticle(pages, key: unknownSong))
        XCTAssertEqual(SongLinkClient.artistArticle(pages, key: unknownSong)?.lastPathComponent, "Stromae")
        XCTAssertNil(SongLinkClient.songArticle(pages, key: try XCTUnwrap(SongKey(artist: "Someone Else", title: "Alors on danse"))),
                     "A song of the same name by another artist is not shared.")
    }

    func testYouTubeErrorsExplainQuotaAndKeyProblems() {
        XCTAssertEqual(SongLinkClient.youTubeError(status: 403, data: Data(#"{"error":{"errors":[{"reason":"quotaExceeded"}]}}"#.utf8)), .quotaExceeded)
        XCTAssertEqual(SongLinkClient.youTubeError(status: 400, data: Data(#"{"error":{"message":"API key not valid. Please pass a valid API key."}}"#.utf8)), .invalidAPIKey)
        XCTAssertEqual(SongLinkClient.youTubeError(status: 500, data: Data()), .http(500))
    }

    func testSharedTextNamesTheSongThenItsLinksWithoutTheApp() {
        let text = ShareText.song(title: "Alors on danse", artist: "Stromae",
                                  links: [URL(string: "https://en.wikipedia.org/wiki/Alors_on_danse")!, URL(string: "https://www.youtube.com/watch?v=SXoQHp2cQQc")!])
        XCTAssertEqual(text, "Alors on danse — Stromae\nhttps://en.wikipedia.org/wiki/Alors_on_danse\nhttps://www.youtube.com/watch?v=SXoQHp2cQQc")
        XCTAssertFalse(text.localizedCaseInsensitiveContains("macarok"))
        XCTAssertEqual(ShareText.radio(station: "FIP", nowPlaying: nil, website: nil), "FIP")
        XCTAssertEqual(ShareText.podcast(show: "Show", episode: "Episode", link: URL(string: "https://example.org/1")),
                       "Show — Episode\nhttps://example.org/1")
    }

    private func makeStore() throws -> LibraryStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokSongLinks-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
    }
}

private actor URLLog {
    private(set) var urls: [String] = []
    func append(_ url: String) { urls.append(url) }
}

private actor Responses {
    private var musicBrainzEmpty = false
    func setMusicBrainzEmpty() { musicBrainzEmpty = true }
    func answer(_ url: String) -> (Data, HTTPURLResponse) {
        let body: String
        if url.contains("musicbrainz.org/ws/2/recording?") {
            body = musicBrainzEmpty ? #"{"recordings":[]}"# : #"{"recordings":[{"id":"r1","score":100,"title":"Alors on danse"},{"id":"r2","score":100,"title":"Other"}]}"#
        } else if url.contains("musicbrainz.org/ws/2/recording/r1") {
            body = #"{"relations":[{"url":{"resource":"https://music.youtube.com/watch?v=gUbeQ7eb3nc"}},{"url":{"resource":"https://www.youtube.com/watch?v=SXoQHp2cQQc"}}]}"#
        } else if url.contains("youtube.com/oembed") {
            body = #"{"title":"Stromae - Alors On Danse","author_name":"Stromae"}"#
        } else if url.contains("googleapis.com/youtube/v3/search") {
            body = #"{"items":[{"id":{"videoId":"6Qd0ZHlBfmg"},"snippet":{"title":"Radiohead - Paranoid Android&#39;s video","channelTitle":"Radiohead"}},{"id":{"videoId":"fHiGbolFFGw"},"snippet":{"title":"Live","channelTitle":"Radiohead"}}]}"#
        } else { body = "{}" }
        return (Data(body.utf8), HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
