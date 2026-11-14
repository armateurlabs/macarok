import XCTest
import Foundation
@testable import MacarokCore

final class SourceIntegrationTests: XCTestCase {
    func testSubsonicTokenAuthenticationUsesDocumentedDigestAndOriginalStream() throws {
        let transport = SourceTransport(sourceID: "test")
        defer { transport.invalidate() }
        let client = OpenSubsonicClient(baseURL: URL(string: "https://music.example/subsonic")!,
            credentials: .init(username: "joe", password: "sesame"), transport: transport)
        let url = try client.endpointURL("stream", parameters: ["id": "song & one", "format": "raw", "maxBitRate": "0"], salt: "c19b2d")
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.path, "/subsonic/rest/stream.view")
        XCTAssertEqual(query["t"], "26719a1196d2a940705a59634eb18eab")
        XCTAssertEqual(query["id"], "song & one")
        XCTAssertEqual(query["format"], "raw")
        XCTAssertEqual(query["maxBitRate"], "0")
        XCTAssertNil(query["p"])
    }

    func testAPIKeyAuthenticationDoesNotSendPasswordOrUsername() throws {
        let transport = SourceTransport(sourceID: "test")
        defer { transport.invalidate() }
        let client = OpenSubsonicClient(baseURL: URL(string: "http://music.home:4533")!,
            credentials: .init(username: "unused", password: "not-in-the-url", apiKey: "key+/="), transport: transport)
        let url = try client.streamURL(songID: "track-1")
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["apiKey"], "key+/=")
        for name in ["u", "p", "t", "s"] { XCTAssertNil(query[name]) }
        XCTAssertEqual(url.scheme, "http")
    }

    func testServerBaseURLRejectsEmbeddedCredentialsAndIgnoredQuerySecrets() throws {
        let transport = SourceTransport(sourceID: "test")
        defer { transport.invalidate() }
        for address in ["https://user:password@music.example", "https://music.example?apiKey=secret", "https://music.example#secret"] {
            let client = OpenSubsonicClient(baseURL: URL(string: address)!, credentials: .init(apiKey: "separate-key"), transport: transport)
            XCTAssertThrowsError(try client.streamURL(songID: "track-1"))
        }
    }

    func testRangeRejectsInvalidArgumentsAndServersThatIgnoreTheRange() async throws {
        let fixture = NetworkFixture(status: 200, body: "whole file")
        defer { fixture.transport.invalidate() }
        for (offset, length) in [(Int64(-1), Int64(5)), (0, 0), (Int64.max, 2)] {
            do { _ = try await fixture.transport.range(from: fixture.url, offset: offset, length: length); XCTFail("An invalid range must be rejected.") }
            catch SourceNetworkError.invalidRange { }
        }
        do { _ = try await fixture.transport.range(from: fixture.url, offset: 3, length: 4); XCTFail("A complete response must not masquerade as the requested range.") }
        catch SourceNetworkError.invalidRange { }
    }

    func testTransportRejectsURLUserInfoBeforeSendingCredentials() async throws {
        let transport = SourceTransport(sourceID: "test")
        defer { transport.invalidate() }
        do { _ = try await transport.data(from: URL(string: "https://user:password@music.example/audio")!); XCTFail("Credentials belong in the source credential store.") }
        catch SourceNetworkError.invalidURL { }
    }

    func testServerErrorsAreNotTreatedAsAnEmptyLibrary() async throws {
        let fixture = NetworkFixture(status: 200, body: """
        {"subsonic-response":{"status":"failed","error":{"code":40,"message":"Wrong username or password."}}}
        """)
        defer { fixture.transport.invalidate() }
        let client = OpenSubsonicClient(baseURL: fixture.url, credentials: .init(username: "user", password: "password"), transport: fixture.transport)
        do { _ = try await client.ping(); XCTFail("An API error must be reported.") }
        catch let error as OpenSubsonicError { XCTAssertEqual(error.code, 40) }
    }

    func testMalformedLibraryResponsesCannotMasqueradeAsAnEmptyLibrary() async throws {
        let payloads = [
            #"{"subsonic-response":{"status":"ok"}}"#,
            #"{"subsonic-response":{"status":"ok","albumList2":[],"album":[]}}"#,
            #"{"subsonic-response":{"status":"ok","albumList2":{"album":"invalid"},"album":{"song":"invalid"}}}"#,
            #"{"subsonic-response":{"status":"ok","albumList2":{"album":[{"name":"Missing ID"}]},"album":{"song":[{"title":"Missing ID"}]}}}"#
        ]
        for payload in payloads {
            let fixture = NetworkFixture(status: 200, body: payload)
            defer { fixture.transport.invalidate() }
            let client = OpenSubsonicClient(baseURL: fixture.url, credentials: .init(apiKey: "test-key"), transport: fixture.transport)
            do { _ = try await client.albums(); XCTFail("Malformed album data must leave the existing library intact.") }
            catch SourceNetworkError.invalidResponse { }
            do { _ = try await client.songs(albumID: "one"); XCTFail("Malformed song data must leave the existing library intact.") }
            catch SourceNetworkError.invalidResponse { }
        }
    }

    func testValidEmptyLibraryContainersRemainSupported() async throws {
        let fixture = NetworkFixture(status: 200, body: #"{"subsonic-response":{"status":"ok","albumList2":{},"album":{}}}"#)
        defer { fixture.transport.invalidate() }
        let client = OpenSubsonicClient(baseURL: fixture.url, credentials: .init(apiKey: "test-key"), transport: fixture.transport)
        let albums = try await client.albums()
        let songs = try await client.songs(albumID: "empty")
        XCTAssertTrue(albums.isEmpty)
        XCTAssertTrue(songs.isEmpty)
    }

    func testAlbumSongsPreserveSourceFolderAndArtworkIdentity() async throws {
        let fixture = NetworkFixture(status: 200, body: """
        {"subsonic-response":{"status":"ok","album":{"id":"album-1","name":"Album","artist":"Artist","year":2005,"coverArt":"cover-1","song":[{"id":"song-1","title":"First","artist":"Artist","track":1,"discNumber":2,"duration":123,"suffix":"flac","path":"Artist/Album/01 First.flac"}]}}}
        """)
        defer { fixture.transport.invalidate() }
        let client = OpenSubsonicClient(baseURL: fixture.url, credentials: .init(username: "user", password: "password"), transport: fixture.transport)
        let songs = try await client.songs(albumID: "album-1")
        XCTAssertEqual(songs.count, 1)
        let track = songs[0].asTrackRecord(sourceID: "source-1")
        XCTAssertEqual(track.remoteID, "song-1")
        XCTAssertEqual(track.remotePath, "Artist/Album/01 First.flac")
        XCTAssertEqual(track.coverArtID, "cover-1")
        XCTAssertEqual(track.album, "Album")
        XCTAssertEqual(track.discNumber, 2)
        XCTAssertEqual(track.format, "FLAC")
        XCTAssertNil(track.fileURL)
        XCTAssertNotEqual(track.id, songs[0].asTrackRecord(sourceID: "source-2").id)
    }

    func testTransportReportsHTTPFailure() async throws {
        let fixture = NetworkFixture(status: 503, body: "Unavailable")
        defer { fixture.transport.invalidate() }
        do { _ = try await fixture.transport.data(from: fixture.url); XCTFail("HTTP errors must be reported.") }
        catch SourceNetworkError.httpStatus(let status) { XCTAssertEqual(status, 503) }
    }

    func testCertificateTrustIsScopedToSourceHostAndPort() {
        let suite = "MacarokTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CertificateTrustStore(defaults: defaults)
        store.trust("FIRST", sourceID: "source-1", host: "Music.Home", port: 4533)
        XCTAssertEqual(store.trustedFingerprint(sourceID: "source-1", host: "music.home", port: 4533), "FIRST")
        XCTAssertNil(store.trustedFingerprint(sourceID: "source-2", host: "music.home", port: 4533))
        XCTAssertNil(store.trustedFingerprint(sourceID: "source-1", host: "music.home", port: 443))
        XCTAssertNil(store.trustedFingerprint(sourceID: "source-1", host: "other.home", port: 4533))
        store.trust("REPLACED", sourceID: "source-1", host: "music.home", port: 4533)
        XCTAssertNotEqual(store.trustedFingerprint(sourceID: "source-1", host: "music.home", port: 4533), "FIRST")
        store.revoke(sourceID: "source-1")
        XCTAssertNil(store.trustedFingerprint(sourceID: "source-1", host: "music.home", port: 4533))
    }
}

private struct NetworkFixture {
    let url: URL
    let transport: SourceTransport

    init(status: Int, body: String) {
        let host = "fixture-\(UUID().uuidString.lowercased()).invalid"
        url = URL(string: "https://\(host)")!
        FixtureURLProtocol.register(host: host, status: status, data: Data(body.utf8))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        transport = SourceTransport(sourceID: host, configuration: config)
    }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var fixtures: [String: (Int, Data)] = [:]

    static func register(host: String, status: Int, data: Data) {
        lock.lock(); defer { lock.unlock() }
        fixtures[host] = (status, data)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return request.url?.host.flatMap { fixtures[$0] } != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let fixture = request.url?.host.flatMap { Self.fixtures[$0] }
        Self.lock.unlock()
        guard let url = request.url, let fixture else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let response = HTTPURLResponse(url: url, statusCode: fixture.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
