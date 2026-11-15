import Foundation
import XCTest
@testable import MacarokCore

final class OpenSubsonicLyricsTests: XCTestCase {
    func testStructuredLyricsConvertMillisecondsAndPositiveOffsetsEarlier() async throws {
        let fixture = LyricsServerFixture(body: #"{"subsonic-response":{"status":"ok","lyricsList":{"structuredLyrics":[{"synced":true,"offset":200,"line":[{"start":1200,"value":"First synthetic line"},{"start":2200,"value":""},{"start":3200,"value":"Last synthetic line"}]}]}}}"#)
        defer { fixture.cleanup() }
        let documents = try await fixture.client.structuredLyrics(songID: "song-1")
        let document = try XCTUnwrap(documents.first)
        XCTAssertEqual(document.source, .openSubsonic)
        XCTAssertEqual(document.providerID, "song-1")
        XCTAssertEqual(document.lines.map(\.startTime), [1, 2, 3])
        XCTAssertEqual(document.lines.map(\.text), ["First synthetic line", "", "Last synthetic line"])
        XCTAssertEqual(document.plainText, "First synthetic line\n\nLast synthetic line")
        let compatibilityText = try await fixture.client.lyrics(songID: "song-1")
        XCTAssertEqual(compatibilityText, document.plainText)
    }

    func testUnsyncedAndIncompleteTimingRemainReadableWithoutInventingTimestamps() async throws {
        let fixture = LyricsServerFixture(body: #"{"subsonic-response":{"status":"ok","lyricsList":{"structuredLyrics":[{"synced":false,"line":[{"value":"Plain line"},{"value":""},{"value":"Second stanza"}]},{"synced":true,"line":[{"start":1000,"value":"Timed line"},{"value":"Missing time"}]}]}}}"#)
        defer { fixture.cleanup() }
        let documents = try await fixture.client.structuredLyrics(songID: "song-2")
        XCTAssertEqual(documents.count, 2)
        XCTAssertFalse(documents[0].isSynced)
        XCTAssertEqual(documents[0].plainText, "Plain line\n\nSecond stanza")
        XCTAssertFalse(documents[1].isSynced)
        XCTAssertEqual(documents[1].plainText, "Timed line\nMissing time")
    }

    func testMissingLyricsAreEmptyAndMalformedContainersAreErrors() async throws {
        let missing = LyricsServerFixture(body: #"{"subsonic-response":{"status":"ok","lyricsList":{}}}"#)
        defer { missing.cleanup() }
        let empty = try await missing.client.structuredLyrics(songID: "song-3")
        XCTAssertTrue(empty.isEmpty)
        let invalid = LyricsServerFixture(body: #"{"subsonic-response":{"status":"ok","lyricsList":{"structuredLyrics":"invalid"}}}"#)
        defer { invalid.cleanup() }
        do {
            _ = try await invalid.client.structuredLyrics(songID: "song-3")
            XCTFail("Malformed lyrics must remain a provider error.")
        } catch SourceNetworkError.invalidResponse { }
    }

    func testMalformedPresentLineFieldsRemainProviderErrors() async throws {
        let documents = [
            #"{"synced":true,"line":"invalid"}"#,
            #"{"synced":true,"line":[{"start":1000,"value":42}]}"#,
            #"{"synced":true,"line":[{"start":"invalid","value":"Synthetic line"}]}"#
        ]
        for document in documents {
            let fixture = LyricsServerFixture(body: "{\"subsonic-response\":{\"status\":\"ok\",\"lyricsList\":{\"structuredLyrics\":[\(document)]}}}")
            defer { fixture.cleanup() }
            do {
                _ = try await fixture.client.structuredLyrics(songID: "malformed")
                XCTFail("Malformed present fields must not become a cached absence.")
            } catch SourceNetworkError.invalidResponse { }
        }
    }
}

private struct LyricsServerFixture {
    let host: String
    let transport: SourceTransport
    let client: OpenSubsonicClient

    init(body: String) {
        host = "lyrics-\(UUID().uuidString.lowercased()).invalid"
        LyricsServerURLProtocol.register(host: host, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LyricsServerURLProtocol.self]
        transport = SourceTransport(sourceID: host, configuration: configuration)
        client = OpenSubsonicClient(baseURL: URL(string: "https://\(host)")!, credentials: .init(apiKey: "fixture-key"), transport: transport)
    }

    func cleanup() {
        transport.invalidate()
        LyricsServerURLProtocol.remove(host: host)
    }
}

private final class LyricsServerURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var bodies: [String: Data] = [:]

    static func register(host: String, body: String) {
        lock.lock(); defer { lock.unlock() }
        bodies[host] = Data(body.utf8)
    }

    static func remove(host: String) {
        lock.lock(); defer { lock.unlock() }
        bodies[host] = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return request.url?.host.flatMap { bodies[$0] } != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let data = request.url?.host.flatMap { Self.bodies[$0] }
        Self.lock.unlock()
        guard let url = request.url, let data else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
