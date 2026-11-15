import Foundation
import XCTest
@testable import MacarokCore

final class LyricsTests: XCTestCase {
    func testLRCOffsetsPrecisionsRepeatedTimestampsAndBlankMarkers() throws {
        let document = LRCParser.parse("""
        [ar:Example Artist]
        [offset:200]
        [00:01.2][00:03.250]Repeated test line
        [00:02.34]Middle test line
        [00:04.000]
        """)
        for (actual, expected) in zip(document.lines.map(\.startTime), [1, 2.14, 3.05, 3.8]) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
        XCTAssertEqual(document.lines.map(\.text), ["Repeated test line", "Middle test line", "Repeated test line", ""])
        let serialized = try XCTUnwrap(document.lrcText)
        XCTAssertFalse(serialized.contains("offset:"))
        for (actual, expected) in zip(LRCParser.parse(serialized).lines.map(\.startTime), document.lines.map(\.startTime)) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
        XCTAssertEqual(LRCParser.parse("[offset:-150]\n[00:01.000]Later").lines.first?.startTime, 1.15)
    }

    func testSharedCUELyricsAreSlicedAfterOffsetAndRebasedOnce() throws {
        let document = LRCParser.parse("[offset:200]\n[00:59.000]Previous track\n[01:01.200]Current track\n[01:05.200]Next track")
        let slice = document.sliced(from: 60, to: 65)
        XCTAssertEqual(slice.lines.map(\.startTime), [1])
        XCTAssertEqual(slice.plainText, "Current track")
        XCTAssertNil(slice.originalLRC)
        XCTAssertEqual(LRCParser.parse(try XCTUnwrap(slice.lrcText)).lines.map(\.startTime), [1])
        let track = TrackRecord(sourceID: "source", duration: 500, startTime: 60, endTime: 65)
        XCTAssertEqual(LyricsLookupQuery(track: track).duration, 5)
    }

    func testUntimedLyricsKeepParagraphsAndMalformedTimestampsDoNotInventTiming() {
        let plain = LRCParser.parse("First test line\n\nSecond test line")
        XCTAssertFalse(plain.isSynced)
        XCTAssertEqual(plain.plainText, "First test line\n\nSecond test line")
        XCTAssertNil(plain.lrcText)
        let malformed = LRCParser.parse("[00:99.00]Invalid time")
        XCTAssertTrue(malformed.lines.isEmpty)
        XCTAssertEqual(malformed.plainText, "[00:99.00]Invalid time")
    }

    func testLRCLIBLookupIdentifiesClientAndAcceptsOnlyMatchingEdition() async throws {
        let stub = LyricsHTTPStub(responses: [.init(body: record())])
        let client = LRCLIBClient(minimumRequestSpacing: 0, transport: { try await stub.send($0) })
        let query = query()
        let result = try await client.lookup(query)
        XCTAssertEqual(result.document?.lines.map(\.startTime), [1])
        XCTAssertEqual(result.document?.source, .lrclib)
        let requests = await stub.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("Macarok") == true)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let parameters = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(parameters?.first(where: { $0.name == "duration" })?.value, "120.0")
        let mismatched = LyricsHTTPStub(responses: [.init(body: record(duration: 124)), .init(body: record(title: "Test Song (Live)"))])
        let guarded = LRCLIBClient(minimumRequestSpacing: 0, transport: { try await mismatched.send($0) })
        let wrongDuration = try await guarded.lookup(query)
        let wrongEdition = try await guarded.lookup(query)
        XCTAssertEqual(wrongDuration, .notFound)
        XCTAssertEqual(wrongEdition, .notFound)
    }

    func testLRCLIBSearchReturnsCandidatesWithoutAutomaticallyChoosingThem() async throws {
        let stub = LyricsHTTPStub(responses: [.init(body: "[\(record()),\(record(id: 2, title: "Test Song (Live)", duration: 160))]")])
        let client = LRCLIBClient(minimumRequestSpacing: 0, transport: { try await stub.send($0) })
        let candidates = try await client.search(query(), text: "custom query")
        XCTAssertEqual(candidates.map(\.id), ["1", "2"])
        XCTAssertEqual(candidates.last?.title, "Test Song (Live)")
        let requests = await stub.requests
        let items = URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.map(\.name), ["q"])
    }

    func testLRCLIBDistinguishesInstrumentalMissingAndInvalidResponses() async throws {
        let stub = LyricsHTTPStub(responses: [.init(body: record(instrumental: true)), .init(status: 404), .init(body: "not json")])
        let client = LRCLIBClient(minimumRequestSpacing: 0, transport: { try await stub.send($0) })
        let instrumental = try await client.lookup(query())
        guard case .instrumental(let document) = instrumental else { return XCTFail("Instrumental must be a successful, distinct result.") }
        XCTAssertTrue(document.isInstrumental)
        let missing = try await client.lookup(query())
        XCTAssertEqual(missing, .notFound)
        do { _ = try await client.lookup(query()); XCTFail("Malformed data must be an error.") }
        catch LyricsError.invalidResponse { }
    }

    func testLRCLIBCooldownAppliesToFollowingManualSearch() async throws {
        let clock = LyricsTestClock()
        let stub = LyricsHTTPStub(responses: [.init(status: 429, headers: ["Retry-After": "10"]), .init(body: "[\(record())]")])
        let client = LRCLIBClient(minimumRequestSpacing: 0, transport: { try await stub.send($0) },
                                 sleep: { clock.advance($0) }, now: { clock.date })
        do { _ = try await client.lookup(query()); XCTFail("Rate limiting must be reported.") }
        catch LyricsError.rateLimited(let seconds) { XCTAssertEqual(seconds, 10) }
        let values = try await client.search(query())
        XCTAssertEqual(values.count, 1)
        XCTAssertGreaterThanOrEqual(clock.elapsed, 10)
    }

    func testExtremeRetryAfterRemainsCancellableWithoutNumericOverflow() async throws {
        let stub = LyricsHTTPStub(responses: [.init(status: 429, headers: ["Retry-After": "1e40"])])
        let sleeper = LyricsCancellingSleeper()
        let client = LRCLIBClient(minimumRequestSpacing: 0, transport: { try await stub.send($0) },
                                 sleep: { try await sleeper.sleep($0) })
        do { _ = try await client.lookup(query()); XCTFail("Rate limiting must be reported.") }
        catch let error as LyricsError {
            XCTAssertEqual(error.localizedDescription, "The lyrics service is busy. Try again later.")
        }
        do { _ = try await client.search(query()); XCTFail("The blocked request must remain cancellable.") }
        catch is CancellationError { }
        let delays = await sleeper.delays
        XCTAssertEqual(delays, [60])
        let requests = await stub.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testLRCLIBSerializesConcurrentRequestsAndCancelsQueuedWork() async throws {
        let stub = LyricsHTTPStub(responses: Array(repeating: .init(body: record(), delay: 0.05), count: 5))
        let client = LRCLIBClient(minimumRequestSpacing: 0, transport: { try await stub.send($0) })
        let query = query()
        let first = Task { try await client.lookup(query) }
        for _ in 0..<100 {
            if !(await stub.requests.isEmpty) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let cancelled = Task { try await client.lookup(query) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled work must not query the provider.") }
        catch is CancellationError { }
        _ = try await first.value
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { _ = try await client.lookup(query) } }
            try await group.waitForAll()
        }
        let count = await stub.requests.count
        let peak = await stub.peakRequests
        XCTAssertEqual(count, 4)
        XCTAssertEqual(peak, 1)
    }

    func testPersistentCacheExpiresMissesAndSeparatesSourcesAndMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let query = LyricsLookupQuery(track: fixture.track)
        let now = Date(timeIntervalSince1970: 1_000)
        try fixture.store.saveLyrics(.notFound, for: query, now: now)
        XCTAssertEqual(try fixture.store.cachedLyrics(for: query, now: now.addingTimeInterval(899))?.result, .notFound)
        XCTAssertNil(try fixture.store.cachedLyrics(for: query, now: now.addingTimeInterval(900)))
        let document = LyricsDocument(plainText: "Cached test lyrics", source: .lrclib)
        try fixture.store.saveLyrics(.found(document), for: query, now: now)
        let reopened = try LibraryStore(url: fixture.url)
        XCTAssertEqual(try reopened.cachedLyrics(for: query)?.result.document, document)
        var otherSource = query; otherSource.sourceID = "different-source"
        XCTAssertNil(try reopened.cachedLyrics(for: otherSource))
        var edited = fixture.track; edited.title = "Edited metadata"
        try fixture.store.upsertTracks([edited])
        XCTAssertNil(try reopened.cachedLyrics(for: LyricsLookupQuery(track: edited)))
        try fixture.store.saveLyrics(.found(document), for: query)
        XCTAssertNil(try reopened.cachedLyrics(for: LyricsLookupQuery(track: edited)), "A late pre-edit response must not enter the new metadata cache.")
    }

    func testManualCorrectionsSurviveMetadataEditsAndAutomaticWrites() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let corrected = LyricsDocument(plainText: "My corrected lyrics", source: .manual)
        try fixture.store.saveLyrics(.found(corrected), for: LyricsLookupQuery(track: fixture.track), manual: true)
        var edited = fixture.track; edited.artist = "Corrected Artist"
        try fixture.store.upsertTracks([edited])
        let query = LyricsLookupQuery(track: edited)
        try fixture.store.saveLyrics(.found(.init(plainText: "Automatic result", source: .lrclib)), for: query)
        XCTAssertEqual(try fixture.store.cachedLyrics(for: query)?.result.document, corrected)
        XCTAssertEqual(try fixture.store.cachedLyrics(for: query)?.isManual, true)
        try fixture.store.deleteSource(id: edited.sourceID)
        XCTAssertNil(try fixture.store.cachedLyrics(for: query))
    }

    func testManualCorrectionFromAnOpenEditorSurvivesConcurrentMetadataEdit() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let originalQuery = LyricsLookupQuery(track: fixture.track)
        var edited = fixture.track; edited.title = "New metadata while the editor is open"
        try fixture.store.upsertTracks([edited])
        let correction = LyricsDocument(plainText: "Intentional correction", source: .manual)
        try fixture.store.saveLyrics(.found(correction), for: originalQuery, manual: true)
        let saved = try fixture.store.cachedLyrics(for: LyricsLookupQuery(track: edited))
        XCTAssertEqual(saved?.result.document, correction)
        XCTAssertEqual(saved?.isManual, true)
    }

    func testResolverPrioritizesManualThenLocalAndCacheBeforeNetwork() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let stub = LyricsHTTPStub(responses: [.init(body: record())])
        let resolver = LyricsResolver(client: LRCLIBClient(minimumRequestSpacing: 0, transport: { try await stub.send($0) }))
        let query = LyricsLookupQuery(track: fixture.track)
        let cached = LyricsDocument(plainText: "Cached", source: .lrclib)
        let local = LyricsDocument(plainText: "Local", source: .sidecar)
        try fixture.store.saveLyrics(.found(cached), for: query)
        let localResult = try await resolver.resolve(track: fixture.track, store: fixture.store, local: { _ in local })
        XCTAssertEqual(localResult.document, local)
        let manual = LyricsDocument(plainText: "Manual", source: .manual)
        try fixture.store.saveLyrics(.found(manual), for: query, manual: true)
        let overridden = try await resolver.resolve(track: fixture.track, store: fixture.store, local: { _ in local })
        XCTAssertEqual(overridden.document, manual)
        try fixture.store.removeLyrics(for: query)
        try fixture.store.saveLyrics(.found(cached), for: query)
        let cachedResult = try await resolver.resolve(track: fixture.track, store: fixture.store)
        XCTAssertEqual(cachedResult.document, cached)
        let requests = await stub.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testResolverUsesServerBeforeWebAndDoesNotCacheProviderFailuresAsMisses() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let stub = LyricsHTTPStub(responses: [.init(status: 500)])
        let resolver = LyricsResolver(client: LRCLIBClient(minimumRequestSpacing: 0, transport: { try await stub.send($0) }))
        let server = LyricsDocument(plainText: "Server result", source: .openSubsonic)
        let result = try await resolver.resolve(track: fixture.track, store: fixture.store, server: { _ in server })
        XCTAssertEqual(result.document, server)
        try fixture.store.removeLyrics(for: LyricsLookupQuery(track: fixture.track))
        do { _ = try await resolver.resolve(track: fixture.track, store: fixture.store); XCTFail("A provider failure must stay an error.") }
        catch LyricsError.httpStatus(500) { }
        XCTAssertNil(try fixture.store.cachedLyrics(for: LyricsLookupQuery(track: fixture.track)))
    }

    private func query() -> LyricsLookupQuery { .init(sourceID: "source", trackID: "track", title: "Test Song", artist: "Test Artist", album: "Test Album", duration: 120) }

    private func record(id: Int = 1, title: String = "Test Song", duration: Double = 120, instrumental: Bool = false) -> String {
        let value: [String: Any] = ["id": id, "trackName": title, "artistName": "Test Artist", "albumName": "Test Album",
                                    "duration": duration, "instrumental": instrumental,
                                    "plainLyrics": instrumental ? (NSNull() as Any) : "First test line",
                                    "syncedLyrics": instrumental ? (NSNull() as Any) : "[00:01.000]First test line"]
        return String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }

    private struct Fixture {
        let directory: URL
        let url: URL
        let store: LibraryStore
        let track: TrackRecord
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            url = directory.appendingPathComponent("library.sqlite")
            store = try LibraryStore(url: url)
            let source = SourceRecord(kind: .openSubsonic, name: "Test", location: "https://example.invalid")
            track = TrackRecord(sourceID: source.id, title: "Test Song", artist: "Test Artist", album: "Test Album", duration: 120)
            try store.saveSource(source); try store.upsertTracks([track])
        }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }
}

private actor LyricsHTTPStub {
    struct Reply: Sendable {
        var status = 200
        var body = ""
        var headers: [String: String] = [:]
        var delay: TimeInterval = 0
    }
    var requests: [URLRequest] = []
    var peakRequests = 0
    private var activeRequests = 0
    private var responses: [Reply]
    init(responses: [Reply]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request); activeRequests += 1
        peakRequests = max(peakRequests, activeRequests)
        defer { activeRequests -= 1 }
        let reply = responses.isEmpty ? Reply(status: 404) : responses.removeFirst()
        if reply.delay > 0 { try await Task.sleep(for: .seconds(reply.delay)) }
        return (Data(reply.body.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                                    httpVersion: "HTTP/1.1", headerFields: reply.headers)!)
    }
}

private final class LyricsTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    var elapsed: TimeInterval { lock.lock(); defer { lock.unlock() }; return offset }
    var date: Date { Date(timeIntervalSince1970: 1_000 + elapsed) }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; offset += seconds }
}

private actor LyricsCancellingSleeper {
    var delays: [TimeInterval] = []
    func sleep(_ seconds: TimeInterval) throws {
        delays.append(seconds)
        throw CancellationError()
    }
}
