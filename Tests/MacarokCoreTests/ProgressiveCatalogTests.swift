import Foundation
import XCTest
@testable import MacarokCore

final class ProgressiveCatalogTests: XCTestCase {
    func testPublishesFirstAlbumAndAwaitsPersistenceBeforeRequestingTheNextAlbum() async throws {
        let fixture = CatalogFixture(pages: [0: ["first", "second"]])
        defer { fixture.close() }
        let probe = CatalogProbe()
        let gate = CatalogGate()
        let importing = Task {
            try await fixture.client.streamLibrary(sourceID: "test") { tracks, completed, total in
                await probe.append(tracks, completed: completed, total: total)
                if completed == 1 { await gate.wait() }
            }
        }
        let firstPublished = await probe.waitForCount(1)
        XCTAssertTrue(firstPublished)
        XCTAssertEqual(fixture.requests, ["list:0", "album:first"], "The next request must wait until the consumer finishes its batch.")
        let first = await probe.snapshot()
        XCTAssertEqual(first.ids, ["song-first"])
        XCTAssertEqual(first.completed, [1])
        XCTAssertEqual(first.totals, [2])
        await gate.release()
        try await importing.value
        let final = await probe.snapshot()
        XCTAssertEqual(final.ids, ["song-first", "song-second"])
        XCTAssertEqual(final.completed, [1, 2])
    }

    func testLaterAlbumFailureLeavesEarlierPublishedBatchesAvailable() async throws {
        let fixture = CatalogFixture(pages: [0: ["first", "failure", "unrequested"]], failingAlbum: "failure")
        defer { fixture.close() }
        let probe = CatalogProbe()
        do {
            try await fixture.client.streamLibrary(sourceID: "test") { tracks, completed, total in
                await probe.append(tracks, completed: completed, total: total)
            }
            XCTFail("A failed album must prevent successful snapshot completion.")
        } catch SourceNetworkError.httpStatus(503) { }
        let result = await probe.snapshot()
        XCTAssertEqual(result.ids, ["song-first"])
        XCTAssertEqual(result.completed, [1])
        XCTAssertEqual(fixture.requests, ["list:0", "album:first", "album:failure"])
    }

    func testCancellationAfterPublicationStopsFurtherRequests() async throws {
        let fixture = CatalogFixture(pages: [0: ["first", "unrequested"]])
        defer { fixture.close() }
        let probe = CatalogProbe()
        let importing = Task {
            try await fixture.client.streamLibrary(sourceID: "test") { tracks, completed, total in
                await probe.append(tracks, completed: completed, total: total)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { try await importing.value; XCTFail("Cancellation must reach the caller.") }
        catch is CancellationError { }
        let result = await probe.snapshot()
        XCTAssertEqual(result.ids, ["song-first"])
        XCTAssertEqual(fixture.requests, ["list:0", "album:first"])
    }

    func testCatalogPagesAreConsumedBeforeNextPageAndOverlappingAlbumsAreDeduplicated() async throws {
        let firstPage = (0..<500).map { "album-\($0)" }
        let fixture = CatalogFixture(pages: [0: firstPage, 500: ["album-499", "album-500"]])
        defer { fixture.close() }
        let probe = CatalogProbe()
        try await fixture.client.streamLibrary(sourceID: "test") { tracks, completed, total in
            await probe.append(tracks, completed: completed, total: total)
        }
        let result = await probe.snapshot()
        XCTAssertEqual(result.ids.count, 501)
        XCTAssertEqual(Set(result.ids).count, 501)
        XCTAssertEqual(result.completed, Array(1...501))
        XCTAssertNil(result.totals.first!)
        XCTAssertEqual(result.totals.last!, 501)
        let requests = fixture.requests
        XCTAssertEqual(requests[1], "album:album-0", "Songs from the first page must load before requesting further catalog pages.")
        XCTAssertEqual(requests[500], "album:album-499")
        XCTAssertEqual(requests[501], "list:500")
        XCTAssertEqual(requests[502], "album:album-500")
        XCTAssertEqual(requests.filter { $0 == "album:album-499" }.count, 1)
    }

    func testRepeatingFullCatalogPageFailsRatherThanCompletingAPartialSnapshot() async throws {
        let page = (0..<500).map { "album-\($0)" }
        let fixture = CatalogFixture(pages: [0: page, 500: page])
        defer { fixture.close() }
        let probe = CatalogProbe()
        do {
            try await fixture.client.streamLibrary(sourceID: "test") { tracks, completed, total in
                await probe.append(tracks, completed: completed, total: total)
            }
            XCTFail("Repeated pages must not authorize missing-track reconciliation.")
        } catch SourceNetworkError.invalidResponse { }
        let result = await probe.snapshot()
        XCTAssertEqual(result.completed.last, 500)
        XCTAssertEqual(fixture.requests.filter { $0.hasPrefix("list:") }, ["list:0", "list:500"])
    }

    func testEmptyAlbumsArePublishedAndLegacyCollectionStillReturnsAllTracks() async throws {
        let fixture = CatalogFixture(pages: [0: ["empty", "second"]], emptyAlbums: ["empty"])
        defer { fixture.close() }
        let probe = CatalogProbe()
        try await fixture.client.streamLibrary(sourceID: "test") { tracks, completed, total in
            await probe.append(tracks, completed: completed, total: total)
        }
        let result = await probe.snapshot()
        XCTAssertEqual(result.batchSizes, [0, 1])
        XCTAssertEqual(result.completed, [1, 2])
        let tracks = try await fixture.client.fetchLibrary(sourceID: "test")
        XCTAssertEqual(tracks.map(\.id), ["song-second"])
    }
}

private actor CatalogProbe {
    private var ids: [String] = []
    private var completed: [Int] = []
    private var totals: [Int?] = []
    private var batchSizes: [Int] = []
    func append(_ tracks: [RemoteTrack], completed: Int, total: Int?) {
        ids.append(contentsOf: tracks.map(\.id))
        self.completed.append(completed)
        totals.append(total)
        batchSizes.append(tracks.count)
    }
    func snapshot() -> (ids: [String], completed: [Int], totals: [Int?], batchSizes: [Int]) {
        (ids, completed, totals, batchSizes)
    }
    func waitForCount(_ count: Int) async -> Bool {
        for _ in 0..<100 {
            if completed.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

private actor CatalogGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private final class CatalogFixture: @unchecked Sendable {
    let host = "catalog-\(UUID().uuidString.lowercased()).invalid"
    let pages: [Int: [String]]
    let failingAlbum: String?
    let emptyAlbums: Set<String>
    private let lock = NSLock()
    private var recordedRequests: [String] = []
    private(set) var transport: SourceTransport!
    var client: OpenSubsonicClient {
        OpenSubsonicClient(baseURL: URL(string: "https://\(host)")!, credentials: .init(apiKey: "fixture-key"), transport: transport)
    }
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return recordedRequests }

    init(pages: [Int: [String]], failingAlbum: String? = nil, emptyAlbums: Set<String> = []) {
        self.pages = pages; self.failingAlbum = failingAlbum; self.emptyAlbums = emptyAlbums
        CatalogURLProtocol.register(self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocol.self]
        transport = SourceTransport(sourceID: host, configuration: configuration)
    }
    func close() { transport.invalidate(); CatalogURLProtocol.remove(host) }

    func response(for url: URL) throws -> (Int, Data) {
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let payload: [String: Any]
        let label: String
        let status: Int
        if url.lastPathComponent == "getAlbumList2.view" {
            let offset = Int(query["offset"] ?? "") ?? 0
            label = "list:\(offset)"
            payload = ["albumList2": ["album": (pages[offset] ?? []).map { ["id": $0, "name": $0, "artist": "Fixture Artist"] }]]
            status = 200
        } else {
            let id = query["id"] ?? ""
            label = "album:\(id)"
            let songs: [[String: Any]] = emptyAlbums.contains(id) ? [] : [["id": "song-\(id)", "title": "Track \(id)", "duration": 120, "suffix": "flac"]]
            payload = ["album": ["id": id, "name": id, "artist": "Fixture Artist", "song": songs]]
            status = id == failingAlbum ? 503 : 200
        }
        lock.lock(); recordedRequests.append(label); lock.unlock()
        var response = payload
        response["status"] = "ok"
        return (status, try JSONSerialization.data(withJSONObject: ["subsonic-response": response]))
    }
}

private final class CatalogURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var fixtures: [String: CatalogFixture] = [:]
    static func register(_ fixture: CatalogFixture) { lock.lock(); defer { lock.unlock() }; fixtures[fixture.host] = fixture }
    static func remove(_ host: String) { lock.lock(); defer { lock.unlock() }; fixtures[host] = nil }
    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return request.url?.host.flatMap { fixtures[$0] } != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let fixture = request.url?.host.flatMap { Self.fixtures[$0] }; Self.lock.unlock()
        guard let url = request.url, let fixture else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        do {
            let (status, data) = try fixture.response(for: url)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
