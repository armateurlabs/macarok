import XCTest
import Foundation
@testable import MacarokCore

final class BufferedHTTPInputStreamTests: XCTestCase {
    func testCustomBufferPrimesBeforeReturningAndStartsBeforeTheWholeFileDownloads() async throws {
        let fixture = ProgressiveFixture(size: 1024 * 1024, delay: 0.08)
        let stream = BufferedHTTPInputStream(url: fixture.url, transport: fixture.transport, bufferSeconds: 3, durationHint: 8)
        defer { stream.close(); fixture.transport.invalidate() }
        stream.open()
        let first = try await read(stream, count: 64 * 1024)
        XCTAssertEqual(first.count, 64 * 1024)
        XCTAssertEqual(first.data, fixture.data.prefix(first.count))
        let snapshot = stream.snapshot
        XCTAssertEqual(snapshot.targetBytes, 393_216)
        XCTAssertGreaterThanOrEqual(snapshot.bufferedBytes, snapshot.targetBytes - first.count)
        XCTAssertFalse(fixture.finished, "Playback must begin before downloading the complete file.")
    }

    func testMissingTrustedDurationUsesABoundedPodcastBuffer() async throws {
        let fixture = ProgressiveFixture(size: 4 * 1024 * 1024, delay: 0.03)
        // Podcast RSS durations are only display hints. Omitting that hint from the byte stream
        // must not require the entire episode when its RSS duration is shorter than the buffer.
        let stream = BufferedHTTPInputStream(url: fixture.url, transport: fixture.transport,
            bufferBytes: 256 * 1024, bufferSeconds: 2, durationHint: nil)
        defer { stream.close(); fixture.transport.invalidate() }
        stream.open()
        let first = try await read(stream, count: 4096)
        XCTAssertEqual(first.data, fixture.data.prefix(first.count))
        XCTAssertEqual(stream.snapshot.targetBytes, 48_000)
        XCTAssertFalse(fixture.finished)
    }

    func testSeekingWithinRetainedBytesReusesTheRequestWithoutRepriming() async throws {
        let fixture = ProgressiveFixture(size: 768 * 1024, delay: 0.02)
        let stream = BufferedHTTPInputStream(url: fixture.url, transport: fixture.transport,
            bufferBytes: 256 * 1024, bufferSeconds: 2, durationHint: 20)
        defer { stream.close(); fixture.transport.invalidate() }
        stream.open()
        _ = try await read(stream, count: 4096)
        let requests = fixture.offsets

        XCTAssertTrue(stream.setProperty(NSNumber(value: 1024), forKey: .fileCurrentOffsetKey))
        XCTAssertFalse(stream.snapshot.isBuffering)
        let backward = try await read(stream, count: 1024)
        XCTAssertEqual(backward.data, fixture.data.subdata(in: 1024..<2048))
        XCTAssertEqual(fixture.offsets, requests)

        let offset = 64 * 1024
        XCTAssertTrue(stream.setProperty(NSNumber(value: offset), forKey: .fileCurrentOffsetKey))
        XCTAssertFalse(stream.snapshot.isBuffering)
        let forward = try await read(stream, count: 4096)
        XCTAssertEqual(forward.data, fixture.data.subdata(in: offset..<(offset + 4096)))
        XCTAssertEqual(fixture.offsets, requests, "Nearby compressed-frame seeks must reuse retained bytes.")
    }

    func testShortResponseDrainsEvenWhenSmallerThanTheBufferTarget() async throws {
        let fixture = ProgressiveFixture(size: 16 * 1024, delay: 0)
        let stream = BufferedHTTPInputStream(url: fixture.url, transport: fixture.transport, bufferSeconds: 20, durationHint: 1)
        defer { stream.close(); fixture.transport.invalidate() }
        stream.open()
        let result = try await read(stream, count: 32 * 1024)
        XCTAssertEqual(result.data, fixture.data)
        let end = try await read(stream, count: 1)
        XCTAssertEqual(end.count, 0)
        XCTAssertEqual(stream.streamStatus, .atEnd)
    }

    func testLargeResponsePreservesBytesAcrossMultipleBufferCompactions() async throws {
        let fixture = ProgressiveFixture(size: 3 * 1024 * 1024 + 19, delay: 0)
        // Prime the whole response so each compaction retains an unread tail.
        let stream = BufferedHTTPInputStream(url: fixture.url, transport: fixture.transport,
            bufferSeconds: 1, durationHint: 1)
        defer { stream.close(); fixture.transport.invalidate() }
        stream.open()
        var received = Data()
        while true {
            let result = try await read(stream, count: 64 * 1024 + 17)
            guard result.count > 0 else {
                XCTAssertEqual(result.count, 0)
                break
            }
            received.append(result.data)
            XCTAssertEqual(stream.snapshot.offset, UInt64(received.count))
        }
        XCTAssertEqual(received, fixture.data)
        XCTAssertEqual(stream.streamStatus, .atEnd)
    }

    func testSeekAndCloseAfterBufferCompaction() async throws {
        let fixture = ProgressiveFixture(size: 2 * 1024 * 1024 + 61, delay: 0)
        let stream = BufferedHTTPInputStream(url: fixture.url, transport: fixture.transport,
            bufferSeconds: 1, durationHint: 1)
        defer { stream.close(); fixture.transport.invalidate() }
        stream.open()
        let first = try await read(stream, count: 1024 * 1024)
        XCTAssertEqual(first.data, fixture.data.prefix(first.count))
        XCTAssertEqual(first.count, 1024 * 1024)
        let afterCompaction = try await read(stream, count: 4093)
        XCTAssertEqual(afterCompaction.data, fixture.data.subdata(in: first.count..<(first.count + 4093)))

        let offset = 196_613
        XCTAssertTrue(stream.setProperty(NSNumber(value: offset), forKey: .fileCurrentOffsetKey))
        let afterSeek = try await read(stream, count: 65_539)
        XCTAssertEqual(afterSeek.data, fixture.data.subdata(in: offset..<(offset + 65_539)))
        XCTAssertEqual(stream.snapshot.offset, UInt64(offset + 65_539))
        stream.close()
        let afterClose = try await read(stream, count: 1)
        XCTAssertEqual(afterClose.count, 0)
        XCTAssertEqual(stream.streamStatus, .closed)
    }

    func testSeekUsesValidatedByteRangesAndDiscardsTheOldGeneration() async throws {
        let fixture = ProgressiveFixture(size: 2 * 1024 * 1024, delay: 0.02)
        let stream = BufferedHTTPInputStream(url: fixture.url, transport: fixture.transport,
            bufferBytes: 256 * 1024, durationHint: 64)
        defer { stream.close(); fixture.transport.invalidate() }
        stream.open()
        _ = try await read(stream, count: 4096)
        let offset = 1_572_864
        XCTAssertTrue(stream.setProperty(NSNumber(value: offset), forKey: .fileCurrentOffsetKey))
        let result = try await read(stream, count: 4096)
        XCTAssertEqual(result.data, fixture.data.subdata(in: offset..<(offset + 4096)))
        XCTAssertEqual(stream.property(forKey: .fileCurrentOffsetKey) as? NSNumber, NSNumber(value: offset + 4096))
        XCTAssertTrue(fixture.offsets.contains(UInt64(offset)))
        XCTAssertTrue(stream.setProperty(NSNumber(value: fixture.data.count), forKey: .fileCurrentOffsetKey))
        let end = try await read(stream, count: 1)
        XCTAssertEqual(end.count, 0)
    }

    func testCloseCancelsTheRequestAndUnblocksTheDecoder() async throws {
        let fixture = ProgressiveFixture(size: 1024 * 1024, delay: 0.1)
        let stream = BufferedHTTPInputStream(url: fixture.url, transport: fixture.transport, bufferSeconds: 120, durationHint: 10)
        defer { stream.close(); fixture.transport.invalidate() }
        stream.open()
        let reading = Task { try await read(stream, count: 4096) }
        try await Task.sleep(for: .milliseconds(120))
        stream.close()
        let result = try await reading.value
        XCTAssertEqual(result.count, 0)
        for _ in 0..<30 where fixture.stoppedRequests == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(fixture.stoppedRequests, 0)
        XCTAssertEqual(stream.streamStatus, .closed)
    }

    func testInvalidRangeIsRejectedInsteadOfPlayingWrongBytes() async throws {
        let fixture = ProgressiveFixture(size: 128 * 1024, delay: 0, invalidRange: true)
        let stream = BufferedHTTPInputStream(url: fixture.url, transport: fixture.transport)
        defer { stream.close(); fixture.transport.invalidate() }
        stream.open()
        let result = try await read(stream, count: 4096)
        XCTAssertEqual(result.count, -1)
        XCTAssertTrue(stream.streamError is BufferedHTTPInputStream.StreamFailure)
    }

    func testTruncatedRangeIsAnErrorInsteadOfTheEndOfATrack() async throws {
        let fixture = ProgressiveFixture(size: 128 * 1024, delay: 0, truncateAt: 16 * 1024)
        let stream = BufferedHTTPInputStream(url: fixture.url, transport: fixture.transport)
        defer { stream.close(); fixture.transport.invalidate() }
        stream.open()
        let result = try await read(stream, count: 4096)
        XCTAssertEqual(result.count, -1)
        XCTAssertNotNil(stream.streamError)
        XCTAssertEqual(stream.streamStatus, .error)
    }

    func testCompressedRepresentationIsRejectedBeforeDecoding() async throws {
        let fixture = ProgressiveFixture(size: 128 * 1024, delay: 0, contentEncoding: "gzip")
        let stream = BufferedHTTPInputStream(url: fixture.url, transport: fixture.transport)
        defer { stream.close(); fixture.transport.invalidate() }
        stream.open()
        let result = try await read(stream, count: 4096)
        XCTAssertEqual(result.count, -1)
        XCTAssertNotNil(stream.streamError)
    }

    func testHTTPErrorCancelsTheProgressiveResponseBody() async throws {
        let fixture = ProgressiveFixture(size: 1024 * 1024, delay: 0.1, status: 503)
        defer { fixture.transport.invalidate() }
        do { _ = try await fixture.transport.bytes(for: URLRequest(url: fixture.url)); XCTFail("HTTP errors must be reported.") }
        catch SourceNetworkError.httpStatus(let status) { XCTAssertEqual(status, 503) }
        for _ in 0..<30 where fixture.stoppedRequests == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(fixture.stoppedRequests, 0)
        XCTAssertFalse(fixture.finished)
    }

    func testServerWithoutRangeCanPlayButDoesNotPretendToSeek() async throws {
        let fixture = ProgressiveFixture(size: 16 * 1024, delay: 0, supportsRange: false)
        let stream = BufferedHTTPInputStream(url: fixture.url, transport: fixture.transport)
        defer { stream.close(); fixture.transport.invalidate() }
        XCTAssertNil(stream.supportsSeeking)
        stream.open()
        _ = try await read(stream, count: 10)
        XCTAssertEqual(stream.supportsSeeking, false)
        XCTAssertFalse(stream.setProperty(NSNumber(value: 5000), forKey: .fileCurrentOffsetKey))
    }

    func testContentRangeParserChecksBoundsAndTotal() {
        XCTAssertEqual(BufferedHTTPInputStream.contentRange("bytes 10-19/100")?.start, 10)
        XCTAssertEqual(BufferedHTTPInputStream.contentRange("bytes 10-19/100")?.total, 100)
        XCTAssertNil(BufferedHTTPInputStream.contentRange("bytes 20-10/100"))
        XCTAssertNil(BufferedHTTPInputStream.contentRange("bytes 10-19/19"))
        XCTAssertNil(BufferedHTTPInputStream.contentRange("bytes 10-19/-1"))
        XCTAssertNil(BufferedHTTPInputStream.contentRange("items 10-19/100"))
        XCTAssertNil(BufferedHTTPInputStream.contentRange("bytes 0-18446744073709551615/*"))
    }

    private struct ReadResult: Sendable { let count: Int; let data: Data }
    private enum ReadFailure: Error { case timeout }

    private func read(_ stream: BufferedHTTPInputStream, count: Int) async throws -> ReadResult {
        try await withThrowingTaskGroup(of: ReadResult.self) { group in
            group.addTask {
                var storage = [UInt8](repeating: 0, count: count)
                let count = storage.withUnsafeMutableBufferPointer { stream.read($0.baseAddress!, maxLength: $0.count) }
                return ReadResult(count: count, data: Data(storage.prefix(max(0, count))))
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                stream.close()
                throw ReadFailure.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

private final class ProgressiveFixture: @unchecked Sendable {
    let url: URL
    let transport: SourceTransport
    let data: Data
    let delay: Double
    let supportsRange: Bool
    let invalidRange: Bool
    let truncateAt: Int?
    let contentEncoding: String?
    let status: Int?
    private let lock = NSLock()
    private var completed = false
    private var stops = 0
    private var requestedOffsets: [UInt64] = []

    init(size: Int, delay: Double, supportsRange: Bool = true, invalidRange: Bool = false,
         truncateAt: Int? = nil, contentEncoding: String? = nil, status: Int? = nil) {
        let host = "buffer-\(UUID().uuidString.lowercased()).invalid"
        url = URL(string: "https://\(host)/audio.flac")!
        data = Data((0..<size).map { UInt8($0 % 251) })
        self.delay = delay; self.supportsRange = supportsRange; self.invalidRange = invalidRange
        self.truncateAt = truncateAt; self.contentEncoding = contentEncoding; self.status = status
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProgressiveURLProtocol.self]
        transport = SourceTransport(sourceID: host, configuration: configuration)
        ProgressiveURLProtocol.register(host: host, fixture: self)
    }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return completed }
    var offsets: [UInt64] { lock.lock(); defer { lock.unlock() }; return requestedOffsets }
    var stoppedRequests: Int { lock.lock(); defer { lock.unlock() }; return stops }
    func didRequest(_ offset: UInt64) { lock.lock(); requestedOffsets.append(offset); lock.unlock() }
    func didFinish() { lock.lock(); completed = true; lock.unlock() }
    func didStop() { lock.lock(); stops += 1; lock.unlock() }
}

private final class ProgressiveURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var fixtures: [String: ProgressiveFixture] = [:]
    private let queue = DispatchQueue(label: "MacarokTests.ProgressiveHTTP")
    private let stateLock = NSLock()
    private var stopped = false
    private var fixture: ProgressiveFixture?

    static func register(host: String, fixture: ProgressiveFixture) {
        lock.lock(); fixtures[host] = fixture; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return request.url?.host.flatMap { fixtures[$0] } != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); fixture = request.url?.host.flatMap { Self.fixtures[$0] }; Self.lock.unlock()
        guard let fixture, let url = request.url else { return }
        let raw = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-"
        let offset = UInt64(raw.replacingOccurrences(of: "bytes=", with: "").split(separator: "-").first ?? "0") ?? 0
        fixture.didRequest(offset)
        let start = fixture.supportsRange ? Int(offset) : 0
        guard start < fixture.data.count else {
            let response = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: ["Content-Range": "bytes */\(fixture.data.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocolDidFinishLoading(self); return
        }
        var headers = ["Content-Length": String(fixture.data.count - start), "Content-Type": "audio/flac", "Accept-Ranges": fixture.supportsRange ? "bytes" : "none"]
        if let encoding = fixture.contentEncoding { headers["Content-Encoding"] = encoding }
        if fixture.supportsRange { headers["Content-Range"] = "bytes \(fixture.invalidRange ? start + 1 : start)-\(fixture.data.count - 1)/\(fixture.data.count)" }
        let response = HTTPURLResponse(url: url, statusCode: fixture.status ?? (fixture.supportsRange ? 206 : 200), httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        send(from: start)
    }
    private func send(from offset: Int) {
        queue.asyncAfter(deadline: .now() + (fixture?.delay ?? 0)) { [weak self] in
            guard let self, let fixture = self.fixture else { return }
            self.stateLock.lock(); let stopped = self.stopped; self.stateLock.unlock()
            guard !stopped else { return }
            let limit = min(fixture.truncateAt ?? fixture.data.count, fixture.data.count)
            let end = min(offset + 64 * 1024, limit)
            self.client?.urlProtocol(self, didLoad: fixture.data.subdata(in: offset..<end))
            if end < limit { self.send(from: end) }
            else { fixture.didFinish(); self.client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() {
        stateLock.lock(); stopped = true; stateLock.unlock()
        fixture?.didStop()
    }
}
