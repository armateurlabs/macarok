import Foundation
import XCTest
@testable import MacarokCore

final class RadioAndDiscoveryTests: XCTestCase {
    func testStationStorageKeepsStableQueueReferencesAfterUnfavoriting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        var station = RadioStationRecord(name: "Synthetic Radio", streamURL: "https://radio.invalid/live", directoryID: UUID().uuidString)
        try store.saveRadioStation(station, favorite: true)
        try store.saveQueue(trackIDs: [station.id], currentIndex: 0, position: 0)
        _ = try store.savePlaylist(name: "Stations", trackIDs: [station.id])
        station.name = "Renamed Station"; station.resolvedURL = "https://cdn.invalid/new"
        try store.saveRadioStation(station, favorite: false)
        XCTAssertEqual(try store.sources().first?.kind, .radio)
        XCTAssertEqual(try store.radioStation(id: station.id)?.name, "Renamed Station")
        XCTAssertEqual(try store.radioStation(id: station.id)?.isFavorite, false)
        XCTAssertEqual(try store.loadQueue()?.trackIDs, [station.id])
        XCTAssertNotNil(try store.track(id: station.id))
        XCTAssertEqual(try store.radioStations(query: "renamed").count, 1)
        try store.deleteSource(id: RadioLibrary.sourceID)
        XCTAssertNil(try store.radioStation(id: station.id))
    }

    func testICYFramingSurvivesEveryChunkBoundaryAndPreservesAudio() throws {
        let first = Data("StreamTitle='Synthetic Artist - First';".utf8)
        let second = Data("StreamTitle='Second';".utf8)
        func block(_ metadata: Data) -> Data {
            let count = (metadata.count + 15) / 16
            return Data([UInt8(count)]) + metadata + Data(repeating: 0, count: count * 16 - metadata.count)
        }
        let wire = Data("abcd".utf8) + block(first) + Data("efgh".utf8) + block(second) + Data("ijkl".utf8) + Data([0])
        for chunkSize in 1...wire.count {
            var decoder = try ICYMetadataDecoder(interval: 4)
            var audio = Data(); var updates: [ICYTitleUpdate] = []
            for start in stride(from: 0, to: wire.count, by: chunkSize) {
                let part = decoder.consume(wire.subdata(in: start..<min(wire.count, start + chunkSize)))
                audio.append(part.audio); updates += part.updates
            }
            XCTAssertEqual(audio, Data("abcdefghijkl".utf8))
            XCTAssertEqual(updates.map(\.title), ["Synthetic Artist - First", "Second"])
            XCTAssertEqual(updates.map(\.audioOffset), [4, 8])
        }
        XCTAssertThrowsError(try ICYMetadataDecoder(interval: 0))
    }

    func testICYTitleStopsBeforeTheStreamURLField() throws {
        func block(_ text: String) -> Data {
            let metadata = Data(text.utf8), count = (metadata.count + 15) / 16
            return Data([UInt8(count)]) + metadata + Data(repeating: 0, count: count * 16 - metadata.count)
        }
        var decoder = try ICYMetadataDecoder(interval: 1)
        let wire = Data("a".utf8) + block("StreamTitle='';StreamUrl='';") + Data("b".utf8)
            + block("StreamTitle='Don't Stop';StreamUrl='https://radio.invalid/';") + Data("c".utf8)
            + block("StreamTitle='Artist - Title';")
        XCTAssertEqual(decoder.consume(wire).updates.map(\.title), ["", "Don't Stop", "Artist - Title"])
    }

    func testStreamHeadersDescribeTheStationWithoutServerPlaceholders() throws {
        let url = try XCTUnwrap(URL(string: "https://radio.invalid/live"))
        let announced = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "icy-name": "Synthetic FM", "icy-genre": "Minimal, Techno", "icy-description": "Unspecified description",
            "icy-url": "synthetic.invalid", "icy-br": "192,128", "Content-Type": "audio/mpeg; charset=binary",
            "ice-audio-info": "ice-samplerate=44100;ice-bitrate=96;ice-channels=2"]))
        let info = RadioStreamInfo(response: announced)
        XCTAssertEqual(info, RadioStreamInfo(name: "Synthetic FM", genre: "Minimal, Techno", description: nil,
                                             homepage: URL(string: "https://synthetic.invalid"), bitrate: 192,
                                             sampleRate: 44_100, contentType: "audio/mpeg"))
        let silent = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                   headerFields: ["icy-name": "no name", "icy-url": "javascript:alert(1)"]))
        XCTAssertTrue(RadioStreamInfo(response: silent).isEmpty)
    }

    func testApplePodcastChartKeepsChartOrderAndShowsWithoutAFeed() async throws {
        let requests = RequestLog()
        let catalog = ApplePodcastCatalog(transport: { request in
            await requests.append(request.url!)
            let url = request.url!.absoluteString
            let body: String
            if url.contains("/rss/toppodcasts/") {
                body = #"{"feed":{"entry":[{"id":{"attributes":{"im:id":"2"}}},{"id":{"attributes":{"im:id":"1"}}}]}}"#
            } else if url.contains("/lookup") {
                body = #"{"results":[{"collectionId":1,"collectionName":"First","artistName":"A","feedUrl":"https://feeds.invalid/1","primaryGenreName":"Science","trackCount":12},{"collectionId":2,"collectionName":"Second","artistName":"B","primaryGenreName":"Science"}]}"#
            } else {
                body = #"{"results":[{"collectionId":3,"collectionName":"Found","artistName":"C","feedUrl":"https://feeds.invalid/3"}]}"#
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let top = try await catalog.top(country: "FR", genreID: 1533)
        XCTAssertEqual(top.map(\.title), ["Second", "First"], "Chart order is kept, not lookup order.")
        XCTAssertNil(top[0].feedURL, "A show without a public feed is still listed.")
        XCTAssertEqual(top[1].episodeCount, 12)
        let found = try await catalog.search("science", country: "fr", genreID: 1533)
        XCTAssertEqual(found.map(\.title), ["Found"])
        let urls = await requests.urls.map(\.absoluteString)
        XCTAssertTrue(urls[0].hasPrefix("https://itunes.apple.com/fr/rss/toppodcasts/limit=50/genre=1533/json"))
        XCTAssertTrue(urls[1].contains("id=2,1") && urls[1].contains("country=fr"))
        XCTAssertTrue(urls[2].contains("genreId=1533") && urls[2].contains("country=fr") && urls[2].contains("term=science"))
        _ = try await catalog.top(country: "fr", genreID: 1533)
        let count = await requests.urls.count
        XCTAssertEqual(count, 3, "A chart is cached.")
    }

    func testPodcastDirectoriesNormalizeDedupeCacheAndAvoidCredentials() async throws {
        let probe = DirectoryProbe()
        let json = Data(#"{"results":[{"collectionName":"Synthetic Science","artistName":"Example Publisher","feedUrl":"https://publisher.invalid/rss"},{"trackName":"Duplicate","feedUrl":"https://publisher.invalid/rss"},{"trackName":"Invalid","feedUrl":"file:///private/test"}]}"#.utf8)
        let client = PodcastDirectoryClient(transport: { request in
            await probe.record(request)
            return (json, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, sleep: { _ in })
        let index = try await client.search(query: "Synthetic Science", provider: .podcastIndex)
        let cached = try await client.search(query: "synthetic science", provider: .podcastIndex)
        let apple = try await client.search(query: "Synthetic Science", provider: .apple)
        XCTAssertEqual(index.count, 1); XCTAssertEqual(index, cached)
        XCTAssertEqual(apple.first?.provider, .apple)
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.host, "api.podcastindex.org")
        XCTAssertEqual(requests[1].url?.host, "itunes.apple.com")
        XCTAssertNotNil(requests[0].value(forHTTPHeaderField: "User-Agent"))
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "X-Auth-Key"))
    }

    func testPodcastRateLimitAndMalformedResponseStayErrors() async throws {
        let client = PodcastDirectoryClient(transport: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After":"12"])!)
        }, sleep: { _ in })
        do { _ = try await client.search(query: "example"); XCTFail("Expected throttling") }
        catch PodcastDirectoryError.throttled(let delay) { XCTAssertEqual(delay, 12) }
        let invalid = PodcastDirectoryClient(transport: { request in
            (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do { _ = try await invalid.search(query: "example"); XCTFail("Expected malformed response") }
        catch RadioError.invalidResponse { }
    }

    func testRadioDirectoryFailsOverAndReturnsHLSCapabilityWithoutImporting() async throws {
        let probe = DirectoryProbe()
        let uuid = UUID().uuidString
        let data = Data("[{\"stationuuid\":\"\(uuid)\",\"name\":\"Synthetic Radio\",\"url\":\"https://radio.invalid/live\",\"url_resolved\":\"https://radio.invalid/live\",\"hls\":1,\"bitrate\":128,\"codec\":\"AAC\"}]".utf8)
        let client = RadioBrowserClient(mirrors: [URL(string:"https://first.invalid")!, URL(string:"https://second.invalid")!], transport: { request in
            await probe.record(request)
            if request.url?.host == "first.invalid" { throw URLError(.cannotConnectToHost) }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let results = try await client.search(query: "Synthetic", country: "France", language: "french", tags: "jazz")
        XCTAssertEqual(results.count, 1); XCTAssertEqual(results.first?.isHLS, true)
        XCTAssertEqual(results.first?.directoryID, uuid)
        XCTAssertEqual(results.first?.isFavorite, false)
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].url?.query?.contains("country=France") == true)
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
    }
}

private actor DirectoryProbe {
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}

private actor RequestLog {
    private(set) var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
}
