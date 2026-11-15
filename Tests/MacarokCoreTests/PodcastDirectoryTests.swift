import Foundation
import XCTest
@testable import MacarokCore

final class PodcastDirectoryTests: XCTestCase {
    func testCancelledLateResponseCannotPopulateTheCache() async throws {
        let clock = PodcastDirectoryClock()
        let gate = PodcastDirectoryGate()
        let server = PodcastDirectoryHTTPFixture(replies: [reply(title: "Obsolete"), reply(title: "Current")], firstRequestGate: gate)
        let client = PodcastDirectoryClient(transport: { try await server.send($0) }, sleep: { clock.advance($0) }, now: { clock.date })
        let obsolete = Task { try await client.search(query: "same query") }
        try await waitForGate(gate)
        obsolete.cancel(); await gate.release()
        do { _ = try await obsolete.value; XCTFail("A cancelled response must not become usable search results.") }
        catch is CancellationError { }
        let current = try await client.search(query: "same query")
        XCTAssertEqual(current.first?.title, "Current")
        let requests = await server.requests
        XCTAssertEqual(requests.count, 2, "The cancelled response must not have filled the cache.")
    }

    func testAlreadyCancelledSearchCannotReturnCachedResults() async throws {
        let clock = PodcastDirectoryClock()
        let gate = PodcastDirectoryGate()
        let server = PodcastDirectoryHTTPFixture(replies: [reply(title: "Cached")])
        let client = PodcastDirectoryClient(transport: { try await server.send($0) }, sleep: { clock.advance($0) }, now: { clock.date })
        _ = try await client.search(query: "cached")
        let cancelled = Task { await gate.wait(); return try await client.search(query: "cached") }
        try await waitForGate(gate)
        cancelled.cancel(); await gate.release()
        do { _ = try await cancelled.value; XCTFail("Cancellation must be checked before returning cached results.") }
        catch is CancellationError { }
        let requests = await server.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testCancelledWaitingSearchDoesNotReserveAnUnusedAppleRequestSlot() async throws {
        let clock = PodcastDirectoryClock()
        let gate = PodcastDirectoryGate()
        let sleeper = PodcastDirectorySleeper(clock: clock, firstWaitGate: gate)
        let server = PodcastDirectoryHTTPFixture(replies: [reply(title: "First"), reply(title: "Fresh")])
        let client = PodcastDirectoryClient(transport: { try await server.send($0) }, sleep: { await sleeper.sleep($0) }, now: { clock.date })
        _ = try await client.search(query: "first", provider: .apple)
        let obsolete = Task { try await client.search(query: "obsolete", provider: .apple) }
        try await waitForGate(gate)
        obsolete.cancel(); await gate.release()
        do { _ = try await obsolete.value; XCTFail("The obsolete search must remain cancelled.") }
        catch is CancellationError { }
        let current = try await client.search(query: "fresh", provider: .apple)
        XCTAssertEqual(current.first?.title, "Fresh")
        let delays = await sleeper.delays
        XCTAssertEqual(delays.count, 1, "A cancelled waiter must not consume an additional provider slot.")
        let requests = await server.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testHTTPDateRetryAfterUsesTheInjectedClockAndWaitsInBoundedChunks() async throws {
        let clock = PodcastDirectoryClock()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let deadline = formatter.string(from: clock.date.addingTimeInterval(120))
        let server = PodcastDirectoryHTTPFixture(replies: [.init(status: 503, headers: ["Retry-After": deadline]), reply(title: "Recovered")])
        let sleeper = PodcastDirectorySleeper(clock: clock)
        let client = PodcastDirectoryClient(transport: { try await server.send($0) }, sleep: { await sleeper.sleep($0) }, now: { clock.date })
        do { _ = try await client.search(query: "first"); XCTFail("A throttled response must remain an error.") }
        catch PodcastDirectoryError.throttled(let seconds) { XCTAssertEqual(seconds, 120, accuracy: 0.001) }
        let recovered = try await client.search(query: "second")
        XCTAssertEqual(recovered.first?.title, "Recovered")
        let delays = await sleeper.delays
        XCTAssertEqual(delays.reduce(0, +), 120, accuracy: 0.001)
        XCTAssertTrue(delays.allSatisfy { $0 > 0 && $0 <= 60 })
    }

    func testFreshQueryCacheHasAHardBoundAndEntriesExpireAfterTenMinutes() async throws {
        let clock = PodcastDirectoryClock()
        let server = PodcastDirectoryHTTPFixture(defaultReply: reply(title: "Result"))
        let client = PodcastDirectoryClient(transport: { try await server.send($0) }, sleep: { clock.advance($0) }, now: { clock.date })
        for index in 0..<105 {
            _ = try await client.search(query: "query-\(index)")
            clock.advance(1)
        }
        _ = try await client.search(query: "query-0")
        let afterEviction = await server.requests
        XCTAssertEqual(afterEviction.count, 106, "Old queries must be evicted even when every cache entry is fresh.")
        _ = try await client.search(query: "query-0")
        let cached = await server.requests
        XCTAssertEqual(cached.count, 106)
        clock.advance(600)
        _ = try await client.search(query: "query-0")
        let expired = await server.requests
        XCTAssertEqual(expired.count, 107)
    }

    func testMalformedFeedEntriesAreSkippedAndResultCountIsBounded() async throws {
        var rows: [[String: Any]] = [
            ["collectionName": "No feed"],
            ["collectionName": "Local file", "feedUrl": "file:///private/feed.xml"],
            ["collectionName": "Credentials", "feedUrl": "https://user:password@publisher.invalid/rss"],
            ["collectionName": "Invalid scheme", "feedUrl": "javascript:alert(1)"],
            ["trackName": "Valid fallback title", "artistName": "Publisher", "feedUrl": "https://publisher.invalid/valid.xml", "artworkUrl600": "ftp://publisher.invalid/cover.jpg"],
            ["collectionName": "Duplicate", "feedUrl": "https://publisher.invalid/valid.xml"]
        ]
        rows += (0..<70).map { ["collectionName": "Show \($0)", "feedUrl": "https://publisher.invalid/\($0).xml"] }
        let data = try JSONSerialization.data(withJSONObject: ["results": rows])
        let server = PodcastDirectoryHTTPFixture(replies: [.init(data: data)])
        let client = PodcastDirectoryClient(transport: { try await server.send($0) })
        let results = try await client.search(query: "synthetic")
        XCTAssertEqual(results.count, 50)
        XCTAssertEqual(results.first?.title, "Valid fallback title")
        XCTAssertEqual(results.first?.author, "Publisher")
        XCTAssertNil(results.first?.artworkURL)
        XCTAssertEqual(Set(results.map(\.feedURL)).count, results.count)
        XCTAssertTrue(results.allSatisfy { $0.feedURL.scheme == "https" && $0.feedURL.user == nil })
    }

    private func waitForGate(_ gate: PodcastDirectoryGate) async throws {
        for _ in 0..<100 {
            if await gate.entered { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The synthetic operation did not reach its test gate.")
    }

    private func reply(title: String) -> PodcastDirectoryHTTPFixture.Reply {
        .init(data: try! JSONSerialization.data(withJSONObject: ["results": [["collectionName": title, "feedUrl": "https://publisher.invalid/feed.xml"]]]))
    }
}

private actor PodcastDirectoryHTTPFixture {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var data = Data()
    }
    var requests: [URLRequest] = []
    private var replies: [Reply]
    private let defaultReply: Reply
    private let firstRequestGate: PodcastDirectoryGate?
    init(replies: [Reply] = [], defaultReply: Reply = Reply(), firstRequestGate: PodcastDirectoryGate? = nil) {
        self.replies = replies; self.defaultReply = defaultReply; self.firstRequestGate = firstRequestGate
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let reply = replies.isEmpty ? defaultReply : replies.removeFirst()
        if requests.count == 1 { await firstRequestGate?.wait() }
        return (reply.data, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!)
    }
}

private actor PodcastDirectoryGate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor PodcastDirectorySleeper {
    var delays: [Double] = []
    private let clock: PodcastDirectoryClock
    private let firstWaitGate: PodcastDirectoryGate?
    init(clock: PodcastDirectoryClock, firstWaitGate: PodcastDirectoryGate? = nil) { self.clock = clock; self.firstWaitGate = firstWaitGate }
    func sleep(_ seconds: Double) async {
        delays.append(seconds)
        if delays.count == 1 { await firstWaitGate?.wait() }
        clock.advance(seconds)
    }
}

private final class PodcastDirectoryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double = 2_000_000_000
    var date: Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: seconds) }
    func advance(_ interval: Double) { lock.lock(); defer { lock.unlock() }; seconds += interval }
}
