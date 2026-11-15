import Foundation
import XCTest
@testable import MacarokCore

final class LiveRadioStreamTests: XCTestCase {
    func testLiveRequestStripsICYAndEmitsTitlesOnlyAsTheirAudioIsConsumed() async throws {
        let wire = Data("abcd".utf8) + metadata("First broadcast title") + Data("efgh".utf8) + metadata("Second broadcast title") + Data("ijkl".utf8) + Data([0])
        let fixture = LiveHTTPFixture(routes: ["/live": .init(data: wire, headers: ["icy-metaint":"4", "Accept-Ranges":"bytes"])])
        defer { fixture.close() }
        let titles = LiveTitles()
        let stream = BufferedHTTPInputStream(url: fixture.url("/live"), transport: fixture.transport,
                                            bufferSeconds: 1, live: true, onTitle: { titles.append($0) })
        defer { stream.close() }
        stream.open()
        try await eventually { fixture.finishedPaths.contains("/live") && stream.snapshot.bufferedBytes == 12 }
        XCTAssertEqual(titles.values, [], "Receiving buffered metadata must not display a title ahead of its audio.")
        XCTAssertNil(stream.snapshot.totalBytes)
        XCTAssertNil(stream.property(forKey: .init(rawValue: "NSStreamFileSizeKey")))
        XCTAssertFalse(stream.setProperty(NSNumber(value: 0), forKey: .fileCurrentOffsetKey))
        XCTAssertFalse(stream.setProperty(NSNumber(value: 8), forKey: .fileCurrentOffsetKey))
        let first = try await read(stream, count: 3)
        XCTAssertEqual(first.data, Data("abc".utf8)); XCTAssertEqual(titles.values, [])
        let boundary = try await read(stream, count: 1)
        XCTAssertEqual(boundary.data, Data("d".utf8)); XCTAssertEqual(titles.values, ["First broadcast title"])
        let second = try await read(stream, count: 4)
        XCTAssertEqual(second.data, Data("efgh".utf8)); XCTAssertEqual(titles.values, ["First broadcast title", "Second broadcast title"])
        let last = try await read(stream, count: 8)
        XCTAssertEqual(last.data, Data("ijkl".utf8))
        XCTAssertEqual(stream.snapshot.offset, 12)
        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Icy-MetaData"), "1")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testCloseDiscardsBufferedTitlesAndCancelsABlockedDecoder() async throws {
        let fixture = LiveHTTPFixture(routes: ["/live": .init(data: Data(repeating: 7, count: 4 * 1024 * 1024), chunkSize: 4096, delay: 0.02)])
        defer { fixture.close() }
        let titles = LiveTitles()
        let stream = BufferedHTTPInputStream(url: fixture.url("/live"), transport: fixture.transport,
                                            bufferSeconds: 120, live: true, onTitle: { titles.append($0) })
        stream.open()
        let waiting = Task { try await read(stream, count: 1024) }
        try await eventually { !fixture.requests.isEmpty }
        stream.close()
        let result = try await waiting.value
        XCTAssertEqual(result.count, 0)
        try await eventually { fixture.stoppedRequests > 0 }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(stream.snapshot.bufferedBytes, 0)
        XCTAssertEqual(stream.streamStatus, .closed)
        XCTAssertEqual(titles.values, [])
    }

    func testUnconsumedLiveBufferRemainsBoundedAndCloseDropsQueuedMetadata() async throws {
        let fixture = LiveHTTPFixture(routes: ["/live": .init(data: Data(repeating: 3, count: 8 * 1024 * 1024), chunkSize: 64 * 1024, delay: 0.005)])
        defer { fixture.close() }
        let stream = BufferedHTTPInputStream(url: fixture.url("/live"), transport: fixture.transport,
                                            bufferBytes: 256 * 1024, bufferSeconds: 1, live: true)
        stream.open()
        try await eventually { stream.snapshot.bufferedBytes >= 256 * 1024 }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertLessThanOrEqual(stream.snapshot.bufferedBytes, 320 * 1024)
        XCTAssertNil(stream.snapshot.totalBytes)
        stream.close()
        try await eventually { fixture.stoppedRequests > 0 }
        XCTAssertEqual(stream.snapshot.bufferedBytes, 0)

        let wire = Data("abcd".utf8) + metadata("Must not appear after close") + Data("efgh".utf8) + Data([0])
        let metadataFixture = LiveHTTPFixture(routes: ["/live": .init(data: wire, headers: ["icy-metaint":"4"])])
        defer { metadataFixture.close() }
        let titles = LiveTitles()
        let old = BufferedHTTPInputStream(url: metadataFixture.url("/live"), transport: metadataFixture.transport,
                                         live: true, onTitle: { titles.append($0) })
        old.open()
        try await eventually { old.snapshot.bufferedBytes == 8 }
        old.close()
        let result = try await read(old, count: 8)
        XCTAssertEqual(result.count, 0)
        XCTAssertTrue(titles.values.isEmpty)
    }

    func testMalformedICYAndHLSHeadersAreRejectedBeforeDecoding() async throws {
        for headers in [["icy-metaint":"invalid"], ["icy-metaint":"0"], ["icy-metaint":"16777217"], ["Content-Type":"application/vnd.apple.mpegurl"]] {
            let fixture = LiveHTTPFixture(routes: ["/live": .init(data: Data("not audio".utf8), headers: headers)])
            let stream = BufferedHTTPInputStream(url: fixture.url("/live"), transport: fixture.transport, live: true)
            stream.open()
            let result = try await read(stream, count: 1)
            XCTAssertEqual(result.count, -1)
            XCTAssertNotNil(stream.streamError)
            stream.close(); fixture.close()
        }
    }

    func testResolverUsesRelativeNestedM3UAndPLSWithoutDownloadingAudio() async throws {
        let fixture = LiveHTTPFixture(routes: [
            "/start.m3u": .text("#EXTM3U\nsub/list.pls\n"),
            "/sub/list.pls": .text("[playlist]\nFile2=https://unused.invalid/live\nFile1=../audio.mp3\nNumberOfEntries=2\n")
        ])
        defer { fixture.close() }
        let resolved = try await RadioStreamResolver.resolve(fixture.url("/start.m3u"), transport: fixture.transport)
        XCTAssertEqual(resolved, fixture.url("/audio.mp3"))
        XCTAssertEqual(fixture.requests.compactMap { $0.url?.path }, ["/start.m3u", "/sub/list.pls"])
    }

    func testResolverRejectsLoopsHLSUnsafeEntriesAndOversizedWrappers() async throws {
        let fixture = LiveHTTPFixture(routes: [
            "/loop.m3u": .text("loop.m3u"),
            "/hls.m3u": .text("#EXTM3U\n#EXT-X-TARGETDURATION:6\nsegment.ts\n"),
            "/unsafe.pls": .text("[playlist]\nFile1=file:///private/audio.mp3\nFile2=https://user:secret@music.invalid/live\n"),
            "/large.m3u": .init(data: Data(repeating: 65, count: 1024 * 1024 + 1))
        ])
        defer { fixture.close() }
        for path in ["/loop.m3u", "/hls.m3u", "/unsafe.pls", "/large.m3u", "/live.m3u8"] {
            do { _ = try await RadioStreamResolver.resolve(fixture.url(path), transport: fixture.transport); XCTFail("Accepted unsupported wrapper: \(path)") }
            catch is RadioError { }
        }
        XCTAssertFalse(fixture.requests.contains { $0.url?.path == "/live.m3u8" })
    }

    func testResolverOverallDeadlineCancelsATricklingWrapper() async throws {
        let fixture = LiveHTTPFixture(routes: ["/slow.m3u": .init(data: Data("#EXTM3U\nhttps://radio.invalid/live".utf8), chunkSize: 1, delay: 0.03)])
        defer { fixture.close() }
        let started = ContinuousClock.now
        do {
            _ = try await RadioStreamResolver.resolve(fixture.url("/slow.m3u"), transport: fixture.transport, timeout: .milliseconds(120))
            XCTFail("A wrapper delivering occasional bytes must still respect the overall deadline.")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        try await eventually { fixture.stoppedRequests > 0 }
        XCTAssertFalse(fixture.finishedPaths.contains("/slow.m3u"))
    }

    private func metadata(_ title: String) -> Data {
        let bytes = Data("StreamTitle='\(title)';".utf8), blocks = (bytes.count + 15) / 16
        return Data([UInt8(blocks)]) + bytes + Data(repeating: 0, count: blocks * 16 - bytes.count)
    }
    private struct ReadResult: Sendable { let count: Int; let data: Data }
    private func read(_ stream: BufferedHTTPInputStream, count: Int) async throws -> ReadResult {
        try await withThrowingTaskGroup(of: ReadResult.self) { group in
            group.addTask {
                var storage = [UInt8](repeating: 0, count: count)
                let length = storage.withUnsafeMutableBufferPointer { stream.read($0.baseAddress!, maxLength: $0.count) }
                return ReadResult(count: length, data: Data(storage.prefix(max(0, length))))
            }
            group.addTask { try await Task.sleep(for: .seconds(5)); stream.close(); throw URLError(.timedOut) }
            let result = try await group.next()!
            group.cancelAll(); return result
        }
    }
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("The radio stream did not reach the expected state."); throw URLError(.timedOut)
    }
}

private final class LiveTitles: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ value: String) { lock.lock(); stored.append(value); lock.unlock() }
}

private final class LiveHTTPFixture: @unchecked Sendable {
    struct Route: Sendable {
        var data: Data
        var headers: [String: String] = [:]
        var chunkSize = 64 * 1024
        var delay: TimeInterval = 0
        static func text(_ value: String) -> Route { Route(data: Data(value.utf8), headers: ["Content-Type":"audio/x-mpegurl"]) }
    }
    let host: String
    let routes: [String: Route]
    let transport: SourceTransport
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var finished: [String] = []
    private var stopped = 0
    init(routes: [String: Route]) {
        let host = "live-\(UUID().uuidString.lowercased()).invalid"
        self.host = host; self.routes = routes
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveFixtureProtocol.self]
        transport = SourceTransport(sourceID: host, configuration: configuration)
        LiveFixtureProtocol.register(self)
    }
    func url(_ path: String) -> URL { URL(string: "https://\(host)\(path)")! }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    var finishedPaths: [String] { lock.lock(); defer { lock.unlock() }; return finished }
    var stoppedRequests: Int { lock.lock(); defer { lock.unlock() }; return stopped }
    func didRequest(_ request: URLRequest) { lock.lock(); recorded.append(request); lock.unlock() }
    func didFinish(_ path: String) { lock.lock(); finished.append(path); lock.unlock() }
    func didStop() { lock.lock(); stopped += 1; lock.unlock() }
    func close() { transport.invalidate(); LiveFixtureProtocol.remove(host) }
}

private final class LiveFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var fixtures: [String: LiveHTTPFixture] = [:]
    private let queue = DispatchQueue(label: "MacarokTests.LiveRadioHTTP")
    private let stateLock = NSLock()
    private var stopped = false
    private var fixture: LiveHTTPFixture?
    static func register(_ fixture: LiveHTTPFixture) { registryLock.lock(); fixtures[fixture.host] = fixture; registryLock.unlock() }
    static func remove(_ host: String) { registryLock.lock(); fixtures.removeValue(forKey: host); registryLock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool {
        registryLock.lock(); defer { registryLock.unlock() }
        return request.url?.host.flatMap { fixtures[$0] } != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.registryLock.lock(); fixture = request.url?.host.flatMap { Self.fixtures[$0] }; Self.registryLock.unlock()
        guard let fixture, let url = request.url, let route = fixture.routes[url.path] else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        fixture.didRequest(request)
        var headers = ["Content-Type":"audio/mpeg", "Content-Length":String(route.data.count)]
        headers.merge(route.headers) { _, custom in custom }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        send(route, from: 0, path: url.path)
    }
    private func send(_ route: LiveHTTPFixture.Route, from offset: Int, path: String) {
        queue.asyncAfter(deadline: .now() + route.delay) { [weak self] in
            guard let self else { return }
            self.stateLock.lock(); let stopped = self.stopped; self.stateLock.unlock()
            guard !stopped else { return }
            let end = min(offset + route.chunkSize, route.data.count)
            self.client?.urlProtocol(self, didLoad: route.data.subdata(in: offset..<end))
            if end < route.data.count { self.send(route, from: end, path: path) }
            else { self.fixture?.didFinish(path); self.client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock(); fixture?.didStop() }
}
