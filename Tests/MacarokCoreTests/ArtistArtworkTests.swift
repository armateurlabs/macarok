import Foundation
@testable import MacarokCore
import XCTest

final class ArtistArtworkTests: XCTestCase {
    func testKeySharesPictureAcrossCaseAccentsAndSpacing() {
        XCTAssertEqual(ArtistArtworkKey.make("  Björk "), ArtistArtworkKey.make("bjork"))
        XCTAssertEqual(ArtistArtworkKey.make("Meridian   Atlas"), ArtistArtworkKey.make("meridian atlas"))
        XCTAssertFalse(ArtistArtworkKey.isMeaningful("Unknown Artist"))
        XCTAssertFalse(ArtistArtworkKey.isMeaningful("Various Artists"))
        XCTAssertTrue(ArtistArtworkKey.isMeaningful("Meridian Atlas"))
    }

    func testAutomaticLookupNeverReplacesChosenPicture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try store.saveArtistArtwork(name: "Meridian Atlas", path: nil, origin: nil, manual: false)
        XCTAssertNil(try store.artistArtwork(named: "meridian atlas")?.path)
        try store.saveArtistArtwork(name: "Meridian Atlas", path: "/chosen.image", origin: "File", manual: true)
        try store.saveArtistArtwork(name: "MERIDIAN ATLAS", path: "/automatic.image", origin: "Wikipedia", manual: false)
        let record = try XCTUnwrap(store.artistArtwork(named: "Meridian Atlas"))
        XCTAssertEqual(record.path, "/chosen.image")
        XCTAssertTrue(record.manual)
        XCTAssertEqual(try store.allArtistArtwork().count, 1)
        try store.removeArtistArtwork(named: "meridian atlas")
        XCTAssertNil(try store.artistArtwork(named: "Meridian Atlas"))
    }

    func testWikipediaPrefersArticleNamedAfterArtistAndSkipsLogos() async throws {
        let body = #"""
        {"query":{"pages":[
          {"index":1,"title":"Atlas (disambiguation)","description":"Topics referred to by the same term",
           "thumbnail":{"source":"https://upload.example/thumb/a.jpg"},"original":{"source":"https://upload.example/a.jpg"}},
          {"index":2,"title":"Meridian Atlas (band)","description":"Synth-pop band",
           "thumbnail":{"source":"https://upload.example/thumb/band.jpg"},"original":{"source":"https://upload.example/band.jpg"}},
          {"index":3,"title":"Meridian Atlas","description":"Band logo page",
           "thumbnail":{"source":"https://upload.example/thumb/logo.png"},"original":{"source":"https://upload.example/Meridian_Atlas_logo.svg"}},
          {"index":4,"title":"No Image Page"}
        ]}}
        """#
        let client = WikipediaImageClient { request in
            XCTAssertEqual(request.url?.host, "en.wikipedia.org")
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let all = try await client.artistImages(for: "Meridian Atlas")
        XCTAssertEqual(all.map(\.title), ["Meridian Atlas (band)", "Atlas (disambiguation)"])
        let best = try await client.bestArtistImage(for: "Meridian Atlas")
        XCTAssertEqual(best?.imageURL.absoluteString, "https://upload.example/thumb/band.jpg")
    }

    func testLastFMPlaceholderStarIsIgnored() async throws {
        let placeholder = "https://lastfm.freetls.fastly.net/i/u/300x300/\(LastFMClient.placeholderImageHash).png"
        let replies = [
            ##"{"artist":{"name":"Meridian Atlas","image":[{"#text":"\##(placeholder)","size":"extralarge"}]}}"##,
            ##"{"artist":{"name":"Meridian Atlas","image":[{"#text":"https://img.example/l.jpg","size":"large"},{"#text":"https://img.example/xl.jpg","size":"extralarge"}]}}"##,
        ]
        let counter = Counter()
        let client = LastFMClient(credentials: .init(apiKey: String(repeating: "a", count: 32), sharedSecret: String(repeating: "b", count: 32)),
                                  transport: { request in
            let index = await counter.next()
            return (Data(replies[index].utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let none = try await client.artistImage(artist: "Meridian Atlas")
        XCTAssertNil(none)
        let image = try await client.artistImage(artist: "Meridian Atlas")
        XCTAssertEqual(image?.imageURL.absoluteString, "https://img.example/xl.jpg")
        XCTAssertEqual(image?.thumbnailURL.absoluteString, "https://img.example/l.jpg")
    }
}

private actor Counter {
    private var value = 0
    func next() -> Int { defer { value += 1 }; return value }
}
