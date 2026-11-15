import CryptoKit
import Foundation
import XCTest
@testable import MacarokCore

final class LastFMTests: XCTestCase {
    func testSessionRequiresActualListeningAndNeverCreditsSeekJumps() {
        var session = ListeningSession(track: snapshot(duration: 100), occurrenceID: "play-one")
        let date = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(session.sample(isPlaying: true, isBuffering: false, position: 0, duration: 100, monotonic: 0, date: date).beganPlaying)
        XCTAssertNil(session.sample(isPlaying: true, isBuffering: false, position: 20, duration: 100, monotonic: 20, date: date.addingTimeInterval(20)).submission)
        session.suspend()
        _ = session.sample(isPlaying: true, isBuffering: false, position: 90, duration: 100, monotonic: 21, date: date)
        XCTAssertEqual(session.heardSeconds, 20)
        _ = session.sample(isPlaying: false, isBuffering: false, position: 95, duration: 100, monotonic: 26, date: date)
        _ = session.sample(isPlaying: false, isBuffering: false, position: 95, duration: 100, monotonic: 126, date: date)
        _ = session.sample(isPlaying: true, isBuffering: false, position: 95, duration: 100, monotonic: 127, date: date)
        XCTAssertEqual(session.heardSeconds, 25)
        session.suspend()
        _ = session.sample(isPlaying: true, isBuffering: false, position: 0, duration: 100, monotonic: 128, date: date)
        let qualified = session.sample(isPlaying: true, isBuffering: false, position: 25, duration: 100, monotonic: 153, date: date).submission
        XCTAssertEqual(qualified?.id, "play-one")
        XCTAssertEqual(qualified?.startedAt, date)
        XCTAssertNil(session.finish(monotonic: 180, date: date), "An occurrence must qualify only once.")
    }

    func testShortTracksBufferingSleepAndUnknownDurationRules() {
        var short = ListeningSession(track: snapshot(duration: 30))
        _ = short.sample(isPlaying: true, isBuffering: false, position: 0, duration: 30, monotonic: 0, date: Date())
        XCTAssertNil(short.finish(monotonic: 30, date: Date()))
        var session = ListeningSession(track: snapshot(duration: 1_000))
        _ = session.sample(isPlaying: true, isBuffering: false, position: 0, duration: 1_000, monotonic: 0, date: Date())
        _ = session.sample(isPlaying: true, isBuffering: true, position: 20, duration: 1_000, monotonic: 20, date: Date())
        _ = session.sample(isPlaying: true, isBuffering: true, position: 20, duration: 1_000, monotonic: 120, date: Date())
        session.suspend()
        _ = session.sample(isPlaying: true, isBuffering: false, position: 20, duration: 1_000, monotonic: 1_000, date: Date())
        XCTAssertEqual(session.heardSeconds, 20)
        XCTAssertNotNil(session.sample(isPlaying: true, isBuffering: false, position: 240, duration: 1_000, monotonic: 1_220, date: Date()).submission)
        var unknown = ListeningSession(track: snapshot(duration: 0))
        _ = unknown.sample(isPlaying: true, isBuffering: false, position: 0, duration: 0, monotonic: 0, date: Date())
        XCTAssertNotNil(unknown.sample(isPlaying: true, isBuffering: false, position: 240, duration: 0, monotonic: 240, date: Date()).submission)
    }

    func testCUEUsesLogicalDurationAndUnusableMetadataIsExcluded() {
        let cue = TrackRecord(sourceID: "files", title: "Segment", artist: "Performer", duration: 900, startTime: 60, endTime: 100)
        XCTAssertEqual(LastFMTrackSnapshot(track: cue).duration, 40)
        XCTAssertFalse(LastFMTrackSnapshot(track: TrackRecord(sourceID: "files")).isEligible)
    }

    func testPauseAndSeekAccrueFractionsWithoutCountingSleepOrPositionJumps() {
        var session = ListeningSession(track: snapshot(duration: 100))
        let date = Date(timeIntervalSince1970: 1_000)
        _ = session.sample(isPlaying: true, isBuffering: false, position: 0, duration: 100, monotonic: 0, date: date)
        XCTAssertNil(session.suspend(monotonic: 0.75, date: date))
        XCTAssertEqual(session.heardSeconds, 0.75, accuracy: 0.000_001)
        _ = session.sample(isPlaying: true, isBuffering: false, position: 0.75, duration: 100, monotonic: 1_000, date: date)
        XCTAssertNil(session.seek(monotonic: 1_000.25, date: date))
        _ = session.sample(isPlaying: true, isBuffering: false, position: 90, duration: 100, monotonic: 1_000.75, date: date)
        XCTAssertEqual(session.heardSeconds, 1.5, accuracy: 0.000_001)
    }

    func testBrowserTokenSessionAndSignedFormEncoding() async throws {
        let server = LastFMHTTPFixture(replies: [#"{"token":"request-token"}"#, #"{"session":{"name":"listener","key":"session-key","subscriber":"0"}}"#, #"{"nowplaying":{}}"#])
        let client = LastFMClient(credentials: application(), transport: { try await server.send($0) })
        let token = try await client.requestToken()
        let session = try await client.session(token: token)
        XCTAssertEqual(session.username, "listener")
        var track = snapshot(); track.title = "A+B & Café = 100%"
        try await client.nowPlaying(track: track, session: session)
        let requests = await server.requests
        XCTAssertEqual(requests.count, 3)
        for request in requests {
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.httpMethod, "POST")
            let body = decodeForm(request)
            XCTAssertEqual(body["api_sig"], LastFMClient.signature(parameters: body, secret: application().sharedSecret))
            XCTAssertNil(body["sharedSecret"])
        }
        XCTAssertEqual(decodeForm(requests[2])["track"], track.title)
        XCTAssertEqual(decodeForm(requests[1])["token"], "request-token")
        XCTAssertEqual(decodeForm(requests[2])["sk"], "session-key")
        let parameters = ["artist[1]": "B", "artist[10]": "A", "format": "json", "callback": "ignored"]
        let expected = Insecure.MD5.hash(data: Data("artist[10]Aartist[1]Bsecret".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(LastFMClient.signature(parameters: parameters, secret: "secret"), expected)
    }

    func testScrobbleBatchPreservesOriginalSecondsAndHandlesPartialFiltering() async throws {
        let server = LastFMHTTPFixture(replies: [##"{"scrobbles":{"@attr":{"accepted":"1","ignored":"1"},"scrobble":[{"ignoredMessage":{"code":"0","#text":""}},{"ignoredMessage":{"code":"2","#text":"Filtered test track"}}]}}"##])
        let client = LastFMClient(credentials: application(), transport: { try await server.send($0) })
        let first = LastFMSubmission(id: "one", track: snapshot(), startedAt: Date(timeIntervalSince1970: 1_000.9))
        let second = LastFMSubmission(id: "two", track: snapshot(), startedAt: Date(timeIntervalSince1970: 2_000))
        let outcomes = try await client.scrobble([first, second], session: .init(username: "listener", key: "session"))
        XCTAssertEqual(outcomes.map(\.id), ["one", "two"])
        XCTAssertEqual(outcomes.map(\.ignoredCode), [0, 2])
        let requests = await server.requests
        XCTAssertEqual(decodeForm(try XCTUnwrap(requests.first))["timestamp[0]"], "1000")
    }

    func testHTTP200APIErrorsAndRateLimitsRemainTyped() async throws {
        let server = LastFMHTTPFixture(replies: [#"{"error":9,"message":"Invalid session"}"#, #"{"error":29,"message":"Rate limited"}"#])
        let client = LastFMClient(credentials: application(), transport: { try await server.send($0) })
        do { _ = try await client.requestToken(); XCTFail("HTTP 200 must not hide an API error.") }
        catch let error as LastFMError { XCTAssertTrue(error.isInvalidSession) }
        do { _ = try await client.requestToken(); XCTFail("Rate limiting must not be a success.") }
        catch let error as LastFMError { XCTAssertTrue(error.isRetryable) }
        let limited = LastFMHTTPFixture(replies: [#"{"error":29,"message":"Rate limited"}"#], status: 429, headers: ["Retry-After": "120"])
        let limitedClient = LastFMClient(credentials: application(), transport: { try await limited.send($0) })
        do { _ = try await limitedClient.requestToken(); XCTFail("A rate-limit response must preserve its cooldown.") }
        catch let error as LastFMError { XCTAssertEqual(error.retryAfter, 120); XCTAssertTrue(error.isRetryable) }
    }

    func testRateLimitBlocksOtherMethodsUntilItsCooldownExpires() async throws {
        let clock = LastFMFixedClock()
        let server = LastFMHTTPFixture(replies: [#"{"error":29,"message":"Rate limited"}"#, #"{"token":"after-cooldown"}"#])
        let client = LastFMClient(credentials: application(), transport: { try await server.send($0) }, now: { clock.date })
        do { _ = try await client.requestToken(); XCTFail("Expected the provider rate limit.") }
        catch let error as LastFMError { XCTAssertTrue(error.isRetryable) }
        do { try await client.nowPlaying(track: snapshot(), session: .init(username: "listener", key: "session")); XCTFail("Now Playing must obey the same cooldown.") }
        catch let error as LastFMError { XCTAssertEqual(error.retryAfter, 60) }
        let blockedRequests = await server.requests
        XCTAssertEqual(blockedRequests.count, 1)
        clock.advance(60)
        let token = try await client.requestToken()
        XCTAssertEqual(token, "after-cooldown")
    }

    func testOutboxPersistsDeduplicatesAndIsolatesAccountsWithoutLibraryForeignKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try LibraryStore(url: url)
        let first = LastFMSubmission(id: "one", track: snapshot(), startedAt: Date(timeIntervalSince1970: 1_000))
        let second = LastFMSubmission(id: "two", track: snapshot(), startedAt: Date(timeIntervalSince1970: 2_000))
        try store.enqueueLastFM(second, accountID: "account-a")
        try store.enqueueLastFM(first, accountID: "account-a")
        try store.enqueueLastFM(first, accountID: "account-a")
        try store.enqueueLastFM(first, accountID: "account-b")
        let reopened = try LibraryStore(url: url)
        XCTAssertEqual(try reopened.lastFMBatch(accountID: "account-a").map(\.submission.id), ["one", "two"])
        XCTAssertEqual(try reopened.lastFMSummary(accountID: "account-b").pending, 1)
        try store.deferLastFM(["one"], accountID: "account-a", until: .distantFuture)
        XCTAssertTrue(try store.lastFMBatch(accountID: "account-a").isEmpty, "A delayed old event must block newer events.")
        try store.completeLastFM([.init(id: "one", ignoredCode: 0, message: "")], accountID: "account-a")
        try store.enqueueLastFM(first, accountID: "account-a")
        XCTAssertEqual(try store.lastFMSummary(accountID: "account-a").pending, 1, "An accepted occurrence cannot be recreated.")
        XCTAssertEqual(try store.lastFMBatch(accountID: "account-a").first?.submission, second)
        try store.clearPendingLastFM(accountID: "account-a")
        try store.enqueueLastFM(first, accountID: "account-a")
        XCTAssertEqual(try store.lastFMSummary(accountID: "account-a").pending, 0, "Clearing pending events must retain accepted occurrence identities.")
        XCTAssertEqual(try store.lastFMSummary(accountID: "account-b").pending, 1)
    }

    private func application() -> LastFMAppCredentials { .init(apiKey: String(repeating: "a", count: 32), sharedSecret: String(repeating: "b", count: 32)) }
    private func snapshot(duration: Double = 120) -> LastFMTrackSnapshot { .init(track: TrackRecord(sourceID: "source", title: "Test Track", artist: "Test Artist", album: "Test Album", duration: duration)) }
    private func decodeForm(_ request: URLRequest) -> [String: String] {
        let text = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        return Dictionary(uniqueKeysWithValues: text.split(separator: "&").map { value in
            let pair = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(pair[0]).removingPercentEncoding!, String(pair[1]).removingPercentEncoding!)
        })
    }
}

private actor LastFMHTTPFixture {
    var requests: [URLRequest] = []
    private var replies: [String]
    private let status: Int
    private let headers: [String: String]
    init(replies: [String], status: Int = 200, headers: [String: String] = [:]) { self.replies = replies; self.status = status; self.headers = headers }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body = replies.isEmpty ? #"{"error":11,"message":"Offline fixture"}"# : replies.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

private final class LastFMFixedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000
    var date: Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: value) }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += seconds }
}
