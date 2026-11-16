import Foundation
import XCTest
@testable import MacarokCore

final class SimilarityTests: XCTestCase {
    func testLastFMParsesSimilarTracksAndArtistsAndTreatsUnknownEntriesAsEmpty() async throws {
        let stub = SimilarityHTTPStub(responses: [
            .init(body: #"{"similartracks":{"track":[{"name":"Song B","match":0.8,"artist":{"name":"Band B"}},{"name":"Song C","match":"0.4","artist":{"name":"Band C"}}]}}"#),
            .init(body: #"{"similarartists":{"artist":{"name":"Band D","match":"0.9"}}}"#),
            .init(body: #"{"error":6,"message":"Track not found"}"#)
        ])
        let client = LastFMClient(credentials: .init(apiKey: String(repeating: "a", count: 32), sharedSecret: String(repeating: "b", count: 32)),
                                  transport: { try await stub.send($0) })
        let tracks = try await client.similarTracks(artist: "Band A", title: "Song A")
        XCTAssertEqual(tracks, [SimilarTrack(artist: "Band B", title: "Song B", score: 0.8), SimilarTrack(artist: "Band C", title: "Song C", score: 0.4)])
        let artists = try await client.similarArtists(artist: "Band A")
        XCTAssertEqual(artists, [SimilarArtist(name: "Band D", score: 0.9)], "A lone object is a one-element list.")
        let unknown = try await client.similarTracks(artist: "Nobody", title: "Nothing")
        XCTAssertEqual(unknown, [])
        let body = await String(data: stub.requests[0].httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("method=track.getSimilar"))
        XCTAssertTrue(body.contains("artist=Band%20A"))
    }

    func testListenBrainzResolvesTheArtistOnceAndNormalizesScores() async throws {
        let stub = SimilarityHTTPStub(responses: [
            .init(body: #"{"artists":[{"id":"other","name":"Band A Tribute","score":100},{"id":"mbid-a","name":"Bänd A","score":98}]}"#),
            .init(body: #"[{"artist_mbid":"mbid-b","name":"Band B","score":200},{"artist_mbid":"mbid-c","name":"Band C","score":50}]"#),
            .init(body: #"[{"artist_mbid":"mbid-b","name":"Band B","score":10}]"#)
        ])
        let client = ListenBrainzClient(transport: { try await stub.send($0) }, musicBrainzSpacing: 0)
        let first = try await client.similarArtists(artist: "Band A")
        XCTAssertEqual(first, [SimilarArtist(name: "Band B", score: 1), SimilarArtist(name: "Band C", score: 0.25)])
        _ = try await client.similarArtists(artist: "BAND A")
        let urls = await stub.requests.map { $0.url!.absoluteString }
        XCTAssertEqual(urls.count, 3, "The MusicBrainz identifier is resolved once.")
        XCTAssertTrue(urls[0].hasPrefix("https://musicbrainz.org/ws/2/artist/"))
        XCTAssertTrue(urls[1].contains("artist_mbids=mbid-a"), "The exact name wins over a higher-scored different artist.")
        let agent = await stub.requests[0].value(forHTTPHeaderField: "User-Agent") ?? ""
        XCTAssertTrue(agent.contains("Macarok"))

        let failing = SimilarityHTTPStub(responses: [.init(status: 503, body: "")])
        do { _ = try await ListenBrainzClient(transport: { try await failing.send($0) }, musicBrainzSpacing: 0).similarArtists(artist: "X"); XCTFail() }
        catch SimilarityError.unavailable { }
    }

    func testCachedProviderReusesAnswersUntilTheyExpireAndNeverCachesErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let clock = SimilarityClock()
        let base = MockSimilarityProvider(tracks: ["a|x": [SimilarTrack(artist: "B", title: "Y", score: 1)]])
        let cached = CachedSimilarityProvider(base, store: store, now: { clock.now })
        _ = try await cached.similarTracks(artist: "A", title: "X")
        _ = try await cached.similarTracks(artist: "a", title: "x")
        _ = try await cached.similarArtists(artist: "A")
        _ = try await cached.similarArtists(artist: "A")
        XCTAssertEqual(base.calls, 2)
        clock.now += 2 * 86_400
        _ = try await cached.similarArtists(artist: "A")
        _ = try await cached.similarTracks(artist: "A", title: "X")
        XCTAssertEqual(base.calls, 3, "Empty answers expire after a day; results last a week.")
        let failing = MockSimilarityProvider(error: SimilarityError.unavailable("down"))
        let cachedFailing = CachedSimilarityProvider(failing, store: store, now: { clock.now })
        for _ in 0..<2 { _ = try? await cachedFailing.similarArtists(artist: "Z") }
        XCTAssertEqual(failing.calls, 2)
    }

    func testServiceMatchesLibraryRecordingsLenientlyRanksTrackSimilarityFirstAndHonorsExclusions() async throws {
        let library = SimilarityLibrary(tracks: [
            track("seed", "Seed Song", "Band A"),
            track("a2", "Other Song", "Band A"),
            track("b1", "01 - Song B (2011 Remaster)", "Band B feat. Guest"),
            track("b1copy", "Song B", "Band B"),
            track("b1live", "Song B (Live)", "Band B"),
            track("c1", "Song C", "Band C"),
            track("d1", "Song D", "Band D"),
            track("unrelated", "Song B", "Other Band")
        ])
        let provider = MockSimilarityProvider(
            tracks: ["band a|seed song": [SimilarTrack(artist: "Band B", title: "Song B", score: 0.9), SimilarTrack(artist: "Missing", title: "Gone", score: 1)]],
            artists: ["band a": [SimilarArtist(name: "Band C", score: 0.8), SimilarArtist(name: "Band D", score: 0.1)]])
        let service = SimilarityService(providers: [provider])
        let result = try await service.candidates(for: [SimilaritySeed(artist: "Band A", title: "Seed Song")], in: library, excluding: ["seed"])
        let ids = result.map(\.track.id)
        XCTAssertTrue(["b1", "b1copy"].contains(ids[0]), "The track-level match ranks first.")
        XCTAssertFalse(ids.contains("b1") && ids.contains("b1copy"), "Copies of one recording appear once.")
        XCTAssertFalse(ids.contains("b1live"), "Another edition is not the similar recording.")
        XCTAssertFalse(ids.contains("unrelated"), "The artist must match.")
        XCTAssertFalse(ids.contains("seed"))
        XCTAssertEqual(Array(ids.dropFirst()), ["c1", "a2", "d1"], "Similar artists rank by score; the seed artist stays low.")

        let excluded = try await service.candidates(for: [SimilaritySeed(artist: "Band A", title: "Seed Song")], in: library,
                                                    excluding: ["seed", SimilarityLibrary.editionKey(library.tracks[3])])
        XCTAssertFalse(excluded.map(\.track.id).contains { $0 == "b1" || $0 == "b1copy" }, "Skipping one copy excludes the other.")

        do { _ = try await SimilarityService(providers: []).candidates(for: [SimilaritySeed(artist: "A", title: "B")], in: library); XCTFail() }
        catch SimilarityError.noProviders { }
        do { _ = try await service.candidates(for: [SimilaritySeed(artist: "Unknown", title: "Nothing")], in: library); XCTFail() }
        catch SimilarityError.noMatches { }
        let down = SimilarityService(providers: [MockSimilarityProvider(error: SimilarityError.unavailable("down"))])
        do { _ = try await down.candidates(for: [SimilaritySeed(artist: "Band A", title: "Seed Song")], in: library); XCTFail() }
        catch SimilarityError.unavailable("down") { }
        let partial = SimilarityService(providers: [MockSimilarityProvider(error: SimilarityError.unavailable("down")), provider])
        let partialIDs = try await partial.candidates(for: [SimilaritySeed(artist: "Band A", title: "Seed Song")], in: library).map(\.track.id)
        XCTAssertFalse(partialIDs.isEmpty, "One unavailable service does not prevent results from another.")
    }

    func testRankingAvoidsBackToBackArtistsCapsArtistsAndHonorsTheLimit() {
        let candidates = [("a1", "A", 9.0), ("a2", "A", 8.0), ("a3", "A", 7.0), ("b1", "B", 6.0), ("c1", "C", 5.0)]
            .map { SimilarityCandidate(track: track($0.0, $0.0, $0.1), score: $0.2) }
        XCTAssertEqual(SimilarityRanking.playlist(candidates, limit: nil).map(\.id), ["a1", "b1", "a2", "c1", "a3"])
        XCTAssertEqual(SimilarityRanking.playlist(candidates, limit: 3).map(\.id), ["a1", "b1", "a2"])
        XCTAssertEqual(SimilarityRanking.playlist(candidates, limit: nil, perArtist: 1).map(\.id), ["a1", "b1", "c1"])
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let next = SimilarityRanking.next(candidates, avoidingArtistOf: track("x", "x", "A"), using: &generator)
            XCTAssertTrue(["b1", "c1"].contains(next?.id ?? ""))
        }
        XCTAssertEqual(SimilarityRanking.next(Array(candidates.prefix(1)), avoidingArtistOf: track("x", "x", "A"), using: &generator)?.id, "a1",
                       "The same artist is allowed when it is the only candidate.")
    }

    private func track(_ id: String, _ title: String, _ artist: String) -> TrackRecord {
        TrackRecord(id: id, sourceID: "source", albumID: "album-\(id)", title: title, artist: artist, album: "Album", duration: 100)
    }
}

final class MockSimilarityProvider: SimilarityProvider, @unchecked Sendable {
    let name = "mock"
    private let lock = NSLock()
    private var count = 0
    let tracks: [String: [SimilarTrack]]
    let artists: [String: [SimilarArtist]]
    let error: Error?
    init(tracks: [String: [SimilarTrack]] = [:], artists: [String: [SimilarArtist]] = [:], error: Error? = nil) {
        self.tracks = tracks; self.artists = artists; self.error = error
    }
    var calls: Int { lock.withLock { count } }
    func similarTracks(artist: String, title: String) async throws -> [SimilarTrack] {
        lock.withLock { count += 1 }
        if let error { throw error }
        return tracks["\(artist.lowercased())|\(title.lowercased())"] ?? []
    }
    func similarArtists(artist: String) async throws -> [SimilarArtist] {
        lock.withLock { count += 1 }
        if let error { throw error }
        return artists[artist.lowercased()] ?? []
    }
}

private final class SimilarityClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

private actor SimilarityHTTPStub {
    struct Reply: Sendable { var status = 200; var body = "" }
    var requests: [URLRequest] = []
    private var responses: [Reply]
    init(responses: [Reply]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let reply = responses.isEmpty ? Reply(status: 404) : responses.removeFirst()
        return (Data(reply.body.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}
