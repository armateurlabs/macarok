import Foundation
import XCTest
@testable import MacarokCore

final class OpenSubsonicScanTests: XCTestCase {
    func testScanStartsFollowsProgressAndReportsTheFinalCount() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScanFixtureProtocol.self]
        let transport = SourceTransport(sourceID: "test.subsonic.scan", configuration: configuration)
        defer { transport.invalidate() }
        ScanFixtureProtocol.reset(statuses: [(true, 10), (true, 640), (false, 1_240)])
        let client = OpenSubsonicClient(baseURL: URL(string: "https://scan-fixture.invalid")!,
                                        credentials: SourceCredentials(username: "admin", password: "secret"), transport: transport)
        var seen: [Int?] = []
        let final = try await OpenSubsonicScanStatus.run(start: { try await client.startScan(fullScan: true) },
                                                         status: { try await client.scanStatus() }, interval: .milliseconds(1)) { seen.append($0.count) }
        XCTAssertFalse(final.scanning)
        XCTAssertEqual(final.count, 1_240)
        XCTAssertEqual(final.lastScan, Date(timeIntervalSince1970: 1_794_916_800))
        XCTAssertEqual(seen, [10, 640, 1_240])
        XCTAssertEqual(ScanFixtureProtocol.endpoints, ["startScan", "getScanStatus", "getScanStatus"])
        XCTAssertEqual(ScanFixtureProtocol.fullScan, "true")
    }

    func testANonAdministratorScanIsRecognizedAsNotAuthorized() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScanFixtureProtocol.self]
        let transport = SourceTransport(sourceID: "test.subsonic.scan.denied", configuration: configuration)
        defer { transport.invalidate() }
        ScanFixtureProtocol.reset(statuses: [], denied: true)
        let client = OpenSubsonicClient(baseURL: URL(string: "https://scan-fixture.invalid")!,
                                        credentials: SourceCredentials(username: "listener", password: "secret"), transport: transport)
        do {
            _ = try await client.startScan()
            XCTFail("A refused scan must throw.")
        } catch {
            XCTAssertTrue(OpenSubsonicError.isNotAuthorized(error))
        }
        XCTAssertNil(ScanFixtureProtocol.fullScan, "A quick scan does not send the full-scan parameter.")
        XCTAssertTrue(OpenSubsonicError.isNotAuthorized(SourceNetworkError.httpStatus(403)))
        XCTAssertFalse(OpenSubsonicError.isNotAuthorized(OpenSubsonicError(code: 40, message: "Wrong password")))
    }
}

private final class ScanFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var queue: [(Bool, Int)] = []
    private static var deniedScan = false
    private static var recorded: [String] = []
    private static var fullScanValue: String?
    static var endpoints: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    static var fullScan: String? { lock.lock(); defer { lock.unlock() }; return fullScanValue }
    static func reset(statuses: [(Bool, Int)], denied: Bool = false) {
        lock.lock(); queue = statuses; deniedScan = denied; recorded = []; fullScanValue = nil; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "scan-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let endpoint = url.deletingPathExtension().lastPathComponent
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        Self.lock.lock()
        Self.recorded.append(endpoint)
        if endpoint == "startScan" { Self.fullScanValue = items.first { $0.name == "fullScan" }?.value }
        let denied = Self.deniedScan
        let next = Self.queue.isEmpty ? (false, 0) : Self.queue.removeFirst()
        Self.lock.unlock()
        let body: String
        if denied {
            body = #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":50,"message":"User not authorized"}}}"#
        } else {
            body = #"{"subsonic-response":{"status":"ok","version":"1.16.1","scanStatus":{"scanning":\#(next.0),"count":\#(next.1),"folderCount":3,"lastScan":"2026-11-17T12:00:00Z"}}}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
