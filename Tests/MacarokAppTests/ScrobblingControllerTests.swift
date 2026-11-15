import Foundation
import XCTest
import MacarokCore
@testable import MacarokApp

@MainActor
final class ScrobblingControllerTests: XCTestCase {
    func testStartupOnlyLoadsSavedCredentialsWithoutContactingLastFM() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let server = ScrobblingHTTPFixture()
        let controller = ScrobblingController(store: fixture.store, credentials: fixture.credentials,
                                               transport: { try await server.send($0) })
        await controller.start()
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.username, "listener")
        let requests = await server.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testOnlyQualifiedMusicQueuesAndDisabledSourcesRadioAndPodcastsAreExcluded() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let clock = ScrobblingTestClock()
        let server = ScrobblingHTTPFixture()
        let controller = ScrobblingController(store: fixture.store, credentials: fixture.credentials,
                                               transport: { try await server.send($0) }, monotonic: { clock.time },
                                               now: { clock.date }, sleep: { _ in throw CancellationError() })
        await controller.start()
        await controller.setSharesNowPlaying(false)
        for kind in [SourceKind.radio, .podcasts] {
            let excluded = SourceRecord(kind: kind, name: "Excluded", location: "https://example.invalid")
            var track = fixture.track; track.sourceID = excluded.id
            controller.begin(track: track, source: excluded)
            controller.update(isPlaying: true, isBuffering: false, position: 0, duration: 40)
            clock.advance(30)
            controller.update(isPlaying: true, isBuffering: false, position: 30, duration: 40)
            controller.end()
        }
        await controller.setSource(fixture.source.id, excluded: true)
        controller.begin(track: fixture.track, source: fixture.source)
        controller.update(isPlaying: true, isBuffering: false, position: 0, duration: 40)
        clock.advance(30)
        controller.update(isPlaying: true, isBuffering: false, position: 30, duration: 40)
        await controller.flush()
        XCTAssertEqual(try fixture.store.lastFMSummary(accountID: fixture.accountID).pending, 0)
        await controller.setSource(fixture.source.id, excluded: false)
        controller.begin(track: fixture.track, source: fixture.source)
        controller.update(isPlaying: true, isBuffering: false, position: 0, duration: 40)
        clock.advance(20)
        controller.update(isPlaying: true, isBuffering: false, position: 20, duration: 40)
        await controller.flush()
        XCTAssertEqual(try fixture.store.lastFMSummary(accountID: fixture.accountID).pending, 1)
        XCTAssertEqual(try fixture.store.track(id: fixture.track.id)?.playCount, 0, "Last.fm qualification must not mutate local listening history.")
        await controller.setEnabled(false)
    }

    func testBrowserAuthorizationStoresSessionAndDisconnectRetainsEachAccountsPendingPlays() async throws {
        let fixture = try Fixture(connected: false)
        defer { fixture.cleanup() }
        let server = ScrobblingHTTPFixture(authSucceeds: true)
        var browserURL: URL?
        let controller = ScrobblingController(store: fixture.store, credentials: fixture.credentials,
                                               transport: { try await server.send($0) }, openBrowser: { browserURL = $0; return true })
        await controller.start()
        XCTAssertFalse(controller.isEnabled)
        await controller.connect()
        XCTAssertTrue(controller.needsAuthorizationCompletion)
        XCTAssertEqual(browserURL?.host, "www.last.fm")
        let items = URLComponents(url: try XCTUnwrap(browserURL), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first(where: { $0.name == "token" })?.value, "fixture-token")
        XCTAssertNil(items?.first(where: { $0.name == "sharedSecret" }))
        await controller.completeAuthorization()
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(try fixture.credentials.load()?.session?.key, "fixture-session")
        let entry = LastFMSubmission(track: LastFMTrackSnapshot(track: fixture.track), startedAt: Date())
        try fixture.store.enqueueLastFM(entry, accountID: fixture.accountID)
        try fixture.store.enqueueLastFM(entry, accountID: "other-account")
        await controller.disconnect()
        XCTAssertNil(try fixture.credentials.load()?.session)
        XCTAssertEqual(try fixture.credentials.load()?.application, fixture.application)
        XCTAssertEqual(try fixture.store.lastFMSummary(accountID: fixture.accountID).pending, 1)
        XCTAssertEqual(try fixture.store.lastFMSummary(accountID: "other-account").pending, 1)
    }

    func testDisablingAndReenablingDoesNotCreateADuplicatePlaybackOccurrence() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let clock = ScrobblingTestClock()
        let server = ScrobblingHTTPFixture()
        let controller = ScrobblingController(store: fixture.store, credentials: fixture.credentials,
                                               transport: { try await server.send($0) }, monotonic: { clock.time }, now: { clock.date },
                                               sleep: { _ in throw CancellationError() })
        await controller.start(); await controller.setSharesNowPlaying(false)
        controller.begin(track: fixture.track, source: fixture.source)
        controller.update(isPlaying: true, isBuffering: false, position: 0, duration: 40)
        clock.advance(20)
        controller.update(isPlaying: true, isBuffering: false, position: 20, duration: 40)
        await controller.flush()
        await controller.setEnabled(false); await controller.setEnabled(true)
        controller.update(isPlaying: true, isBuffering: false, position: 20, duration: 40)
        clock.advance(20)
        controller.update(isPlaying: true, isBuffering: false, position: 40, duration: 40)
        await controller.flush()
        XCTAssertEqual(try fixture.store.lastFMSummary(accountID: fixture.accountID).pending, 1)
        await controller.setEnabled(false)
    }

    func testDisconnectAndReconnectRetainTheAcceptedCurrentOccurrence() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let clock = ScrobblingTestClock()
        let server = ScrobblingHTTPFixture(authSucceeds: true)
        let occurrence = UUID()
        let accepted = LastFMSubmission(id: occurrence.uuidString, track: LastFMTrackSnapshot(track: fixture.track), startedAt: clock.date)
        try fixture.store.enqueueLastFM(accepted, accountID: fixture.accountID)
        try fixture.store.completeLastFM([.init(id: accepted.id, ignoredCode: 0, message: "")], accountID: fixture.accountID)
        let pending = LastFMSubmission(track: accepted.track, startedAt: clock.date)
        try fixture.store.enqueueLastFM(pending, accountID: "other-account")
        let controller = ScrobblingController(store: fixture.store, credentials: fixture.credentials,
                                               transport: { try await server.send($0) }, monotonic: { clock.time }, now: { clock.date },
                                               openBrowser: { _ in true }, sleep: { _ in throw CancellationError() })
        await controller.start(); await controller.setSharesNowPlaying(false)
        controller.begin(track: fixture.track, source: fixture.source, occurrenceID: occurrence)
        await controller.disconnect()
        XCTAssertEqual(try fixture.store.lastFMSummary(accountID: fixture.accountID).pending, 0)
        XCTAssertEqual(try fixture.store.lastFMSummary(accountID: "other-account").pending, 1)
        await controller.connect(); await controller.completeAuthorization()
        controller.update(isPlaying: true, isBuffering: false, position: 20, duration: 40)
        clock.advance(20)
        controller.update(isPlaying: true, isBuffering: false, position: 40, duration: 40)
        await controller.flush()
        XCTAssertEqual(try fixture.store.lastFMSummary(accountID: fixture.accountID).pending, 0)
        let requests = await server.requests
        XCTAssertFalse(requests.contains { String(data: $0.httpBody ?? Data(), encoding: .utf8)?.contains("method=track.scrobble") == true })
        await controller.setEnabled(false)
    }

    func testReconnectingTheSameAccountResumesItsPendingPlays() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let server = ScrobblingHTTPFixture(authSucceeds: true, acceptsScrobbles: true)
        let entry = LastFMSubmission(track: LastFMTrackSnapshot(track: fixture.track), startedAt: Date())
        try fixture.store.enqueueLastFM(entry, accountID: fixture.accountID)
        try fixture.store.enqueueLastFM(entry, accountID: "other-account")
        let controller = ScrobblingController(store: fixture.store, credentials: fixture.credentials,
                                               transport: { try await server.send($0) }, openBrowser: { _ in true },
                                               sleep: { _ in throw CancellationError() })
        await controller.start(); await controller.disconnect()
        XCTAssertEqual(try fixture.store.lastFMSummary(accountID: fixture.accountID).pending, 1)
        await controller.connect(); await controller.completeAuthorization()
        for _ in 0..<100 {
            if try fixture.store.lastFMSummary(accountID: fixture.accountID).pending == 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(try fixture.store.lastFMSummary(accountID: fixture.accountID).pending, 0)
        XCTAssertEqual(try fixture.store.lastFMSummary(accountID: "other-account").pending, 1)
        let requests = await server.requests
        XCTAssertEqual(requests.filter { String(data: $0.httpBody ?? Data(), encoding: .utf8)?.contains("method=track.scrobble") == true }.count, 1)
        await controller.setEnabled(false)
    }

    func testChangingAPIKeysAndAccountNeverSubmitsThePreviousAccountsPendingPlays() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let server = ScrobblingHTTPFixture(authSucceeds: true, acceptsScrobbles: true, sessionUsername: "second-listener")
        var oldTrack = fixture.track; oldTrack.title = "OLD_ACCOUNT_TRACK"
        let oldEntry = LastFMSubmission(track: LastFMTrackSnapshot(track: oldTrack), startedAt: Date(timeIntervalSince1970: 1_000))
        try fixture.store.enqueueLastFM(oldEntry, accountID: fixture.accountID)
        let nextApplication = LastFMAppCredentials(apiKey: String(repeating: "c", count: 32), sharedSecret: String(repeating: "d", count: 32))
        let nextAccount = LastFMCredentialRecord(application: nextApplication, session: .init(username: "second-listener", key: "fixture-session")).accountID!
        var nextTrack = fixture.track; nextTrack.title = "NEW_ACCOUNT_TRACK"
        try fixture.store.enqueueLastFM(.init(track: LastFMTrackSnapshot(track: nextTrack), startedAt: Date()), accountID: nextAccount)
        let controller = ScrobblingController(store: fixture.store, credentials: fixture.credentials,
                                               transport: { try await server.send($0) }, openBrowser: { _ in true },
                                               sleep: { _ in throw CancellationError() })
        await controller.start()
        controller.apiKeyInput = nextApplication.apiKey; controller.apiSecretInput = nextApplication.sharedSecret
        await controller.saveAPIKeys()
        XCTAssertEqual(try fixture.store.lastFMSummary(accountID: fixture.accountID).pending, 1)
        XCTAssertNil(controller.username)
        await controller.connect(); await controller.completeAuthorization()
        for _ in 0..<100 {
            if try fixture.store.lastFMSummary(accountID: nextAccount).pending == 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(try fixture.store.lastFMSummary(accountID: fixture.accountID).pending, 1)
        XCTAssertEqual(try fixture.store.lastFMSummary(accountID: nextAccount).pending, 0)
        let requests = await server.requests
        let scrobbles = requests.compactMap { String(data: $0.httpBody ?? Data(), encoding: .utf8) }.filter { $0.contains("method=track.scrobble") }
        XCTAssertEqual(scrobbles.count, 1)
        XCTAssertTrue(scrobbles.first?.contains("NEW_ACCOUNT_TRACK") == true)
        XCTAssertFalse(scrobbles.contains { $0.contains("OLD_ACCOUNT_TRACK") })
        await controller.setEnabled(false)
    }

    func testDisconnectBlocksReenablingOrConnectingUntilKeychainSaveFinishes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let server = ScrobblingHTTPFixture(authSucceeds: true)
        let controller = ScrobblingController(store: fixture.store, credentials: fixture.credentials,
                                               transport: { try await server.send($0) }, openBrowser: { _ in true })
        await controller.start()
        fixture.credentials.blockNextSave()
        defer { fixture.credentials.releaseBlockedSave() }
        let disconnect = Task { await controller.disconnect() }
        for _ in 0..<100 {
            if fixture.credentials.isSaveBlocked { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(fixture.credentials.isSaveBlocked)
        let busy = controller.isWorking
        XCTAssertTrue(busy)
        if busy { await controller.setEnabled(true); await controller.connect() }
        fixture.credentials.releaseBlockedSave()
        await disconnect.value
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(controller.username)
        let requests = await server.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testInvalidSessionAndConfigurationFailuresSuspendAutomaticDelivery() async throws {
        for code in [9, 13] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let clock = ScrobblingTestClock()
            let server = ScrobblingHTTPFixture(scrobbleError: code)
            let controller = ScrobblingController(store: fixture.store, credentials: fixture.credentials,
                                                   transport: { try await server.send($0) }, monotonic: { clock.time }, now: { clock.date },
                                                   sleep: { _ in throw CancellationError() })
            await controller.start(); await controller.setSharesNowPlaying(false)
            controller.begin(track: fixture.track, source: fixture.source)
            controller.update(isPlaying: true, isBuffering: false, position: 0, duration: 40)
            clock.advance(20)
            controller.update(isPlaying: true, isBuffering: false, position: 20, duration: 40)
            await controller.flush()
            for _ in 0..<100 {
                if !controller.isEnabled { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertFalse(controller.isEnabled)
            XCTAssertEqual(controller.needsReauthentication, code == 9)
            XCTAssertEqual(try fixture.store.lastFMSummary(accountID: fixture.accountID).pending, 1)
            controller.begin(track: fixture.track, source: fixture.source)
            controller.update(isPlaying: true, isBuffering: false, position: 0, duration: 40)
            clock.advance(20)
            controller.update(isPlaying: true, isBuffering: false, position: 20, duration: 40)
            await controller.flush()
            let requests = await server.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    private struct Fixture {
        let directory: URL
        let store: LibraryStore
        let source: SourceRecord
        let track: TrackRecord
        let credentials: ScrobblingMemoryCredentials
        let application: LastFMAppCredentials
        let accountID: String
        init(connected: Bool = true) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScrobblingTests-\(UUID().uuidString)")
            store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
            source = SourceRecord(id: "files", kind: .local, name: "Files", location: directory.path)
            track = TrackRecord(id: "track", sourceID: source.id, title: "Synthetic Track", artist: "Synthetic Artist", duration: 40)
            try store.saveSource(source); try store.upsertTracks([track])
            application = LastFMAppCredentials(apiKey: String(repeating: "a", count: 32), sharedSecret: String(repeating: "b", count: 32))
            let session = LastFMSession(username: "listener", key: "fixture-session")
            accountID = LastFMCredentialRecord(application: application, session: session).accountID!
            credentials = ScrobblingMemoryCredentials(.init(application: application, session: connected ? session : nil))
            var preferences = LastFMPreferences(); preferences.enabled = connected
            try store.saveLastFMPreferences(preferences)
        }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }
}

private final class ScrobblingMemoryCredentials: LastFMCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var record: LastFMCredentialRecord?
    private let saveCondition = NSCondition()
    private var shouldBlockSave = false
    private var saveHasBlocked = false
    private var saveReleased = false
    init(_ value: LastFMCredentialRecord?) { record = value }
    func load() throws -> LastFMCredentialRecord? { lock.lock(); defer { lock.unlock() }; return record }
    func save(_ value: LastFMCredentialRecord) throws {
        saveCondition.lock()
        if shouldBlockSave {
            shouldBlockSave = false; saveHasBlocked = true
            while !saveReleased { saveCondition.wait() }
        }
        saveCondition.unlock()
        lock.lock(); defer { lock.unlock() }; record = value
    }
    func delete() throws { lock.lock(); defer { lock.unlock() }; record = nil }
    var isSaveBlocked: Bool { saveCondition.lock(); defer { saveCondition.unlock() }; return saveHasBlocked && !saveReleased }
    func blockNextSave() { saveCondition.lock(); defer { saveCondition.unlock() }; shouldBlockSave = true; saveHasBlocked = false; saveReleased = false }
    func releaseBlockedSave() { saveCondition.lock(); defer { saveCondition.unlock() }; saveReleased = true; saveCondition.broadcast() }
}

private final class ScrobblingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0
    var time: Double { lock.lock(); defer { lock.unlock() }; return value }
    var date: Date { Date(timeIntervalSince1970: 1_000 + time) }
    func advance(_ amount: Double) { lock.lock(); defer { lock.unlock() }; value += amount }
}

private actor ScrobblingHTTPFixture {
    var requests: [URLRequest] = []
    private let authSucceeds: Bool
    private let scrobbleError: Int?
    private let acceptsScrobbles: Bool
    private let sessionUsername: String
    init(authSucceeds: Bool = false, scrobbleError: Int? = nil, acceptsScrobbles: Bool = false, sessionUsername: String = "listener") {
        self.authSucceeds = authSucceeds; self.scrobbleError = scrobbleError
        self.acceptsScrobbles = acceptsScrobbles; self.sessionUsername = sessionUsername
    }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        if let scrobbleError, body.contains("method=track.scrobble") {
            let data = Data("{\"error\":\(scrobbleError),\"message\":\"Fixture error\"}".utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
        if acceptsScrobbles, body.contains("method=track.scrobble") {
            var form = URLComponents(); form.percentEncodedQuery = body
            let count = form.queryItems?.filter { $0.name.hasPrefix("timestamp[") }.count ?? 0
            let rows = Array(repeating: ["ignoredMessage": ["code": "0", "#text": ""]], count: count)
            let data = try JSONSerialization.data(withJSONObject: ["scrobbles": ["scrobble": rows]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
        guard authSucceeds else { throw URLError(.notConnectedToInternet) }
        let response: String
        if body.contains("method=auth.getToken") { response = #"{"token":"fixture-token"}"# }
        else if body.contains("method=auth.getSession") {
            response = String(data: try JSONSerialization.data(withJSONObject: ["session": ["name": sessionUsername, "key": "fixture-session"]]), encoding: .utf8)!
        }
        else { response = #"{"error":11,"message":"Offline fixture"}"# }
        return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}
