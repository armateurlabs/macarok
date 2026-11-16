import Foundation
import XCTest
@testable import MacarokCore

final class SourceTransportResponseTests: XCTestCase {
    func testStatusNeutralResponsePreservesHTTPBodyWhileDataStillRejectsErrorsAndInvalidURLs() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatusNeutralFixtureProtocol.self]
        let transport = SourceTransport(sourceID: "test.http-status", configuration: configuration)
        defer { transport.invalidate() }
        let request = URLRequest(url: URL(string: "https://status-fixture.invalid/error")!)

        let (data, response) = try await transport.response(for: request)
        XCTAssertEqual(response.statusCode, 400)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "structured error body")
        do {
            _ = try await transport.data(for: request)
            XCTFail("Existing data callers must still require a successful HTTP status.")
        } catch SourceNetworkError.httpStatus(let status) { XCTAssertEqual(status, 400) }
        catch { XCTFail("Unexpected error: \(error)") }
        do {
            _ = try await transport.response(for: URLRequest(url: URL(fileURLWithPath: "/unused/local-file")))
            XCTFail("Status-neutral response must retain URL validation.")
        } catch SourceNetworkError.invalidURL { }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}

private final class StatusNeutralFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "status-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("structured error body".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
