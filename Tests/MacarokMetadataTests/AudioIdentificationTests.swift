import Foundation
import MacarokCore
@testable import MacarokMetadata
import XCTest

final class AudioIdentificationTests: XCTestCase {
    func testAcoustIDResultsDeduplicateRecordingsAndProposeOnlyRecordingMetadata() throws {
        let response = Data(#"""
        {"status":"ok","results":[
          {"id":"acoustid-low","score":0.5,"recordings":[{"id":"1efcf6a0-d090-458c-8e16-f9d8931ab94b","title":"Recording","artists":[{"name":"First","joinphrase":" & "},{"name":"Second"}],"releasegroups":[{"title":"An Edition"}],"duration":200}]},
          {"id":"acoustid-high","score":0.98,"recordings":[{"id":"1efcf6a0-d090-458c-8e16-f9d8931ab94b","title":"Recording","artists":[{"name":"First","joinphrase":" & "},{"name":"Second"}],"releasegroups":[{"title":"Another Edition"},{"title":"Another Edition"}],"duration":200}]},
          {"id":"bad","score":1,"recordings":[{"id":"not-a-musicbrainz-id","title":"Bad"}]}
        ]}
        """#.utf8)
        let matches = try AcoustIDClient.parseResponse(response)
        XCTAssertEqual(matches.count, 1)
        let match = try XCTUnwrap(matches.first)
        XCTAssertEqual(match.score, 0.98)
        XCTAssertEqual(match.artist, "First & Second")
        XCTAssertEqual(match.albums, ["Another Edition"])
        let track = TrackRecord(id: "local", sourceID: "source", albumID: "album", title: "Old", artist: "Unknown", album: "Preserve This Edition")
        let proposal = match.proposal(for: track)
        XCTAssertEqual(Set(proposal.changes.map(\.field)), ["title", "artist"])
        XCTAssertEqual(proposal.applying(to: track).album, "Preserve This Edition")
        XCTAssertNil(proposal.releaseID)
    }

    func testAcoustIDServiceErrorAndEmptyResults() throws {
        XCTAssertThrowsError(try AcoustIDClient.parseResponse(Data(#"{"status":"error","error":{"code":4,"message":"invalid API key"}}"#.utf8))) {
            XCTAssertTrue($0.localizedDescription.contains("invalid API key"))
        }
        XCTAssertEqual(try AcoustIDClient.parseResponse(Data(#"{"status":"ok","results":[]}"#.utf8)), [])
    }

    func testCUEIdentificationNeverFingerprintsWholeAlbum() async {
        do {
            _ = try await ChromaprintClient(executableURL: nil).fingerprint(url: URL(fileURLWithPath: "/unused/album.flac"), isCUETrack: true)
            XCTFail("CUE tracks need an explicit segment fingerprint, not the whole album.")
        } catch AudioIdentificationError.cueSegmentUnsupported { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testLookupSendsOnlyFingerprintDurationAndClientKeyInPOSTBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AcoustIDFixtureProtocol.self]
        let transport = SourceTransport(sourceID: "test.acoustid", configuration: configuration)
        defer { transport.invalidate() }
        let client = AcoustIDClient(transport: transport, endpoint: URL(string: "https://acoustid-fixture.invalid/v2/lookup")!)
        let result = try await client.lookup(AudioFingerprint(duration: 216.9, fingerprint: "AQAB+_fingerprint"), clientKey: "client+key")
        XCTAssertEqual(result, [])
        let request = try XCTUnwrap(AcoustIDFixtureProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded; charset=utf-8")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        let values = try XCTUnwrap(URLComponents(string: "https://fixture.invalid/?" + body)?.queryItems)
        let parameters = Dictionary(uniqueKeysWithValues: values.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(Set(parameters.keys), ["format", "client", "duration", "fingerprint", "meta"])
        XCTAssertEqual(parameters["duration"], "216")
        XCTAssertEqual(parameters["fingerprint"], "AQAB+_fingerprint")
        XCTAssertEqual(parameters["client"], "client+key")
    }

    func testRealBundledHelperFingerprintsGeneratedWAV() async throws {
        guard let path = ProcessInfo.processInfo.environment["MACAROK_FPCALC_PATH"],
              FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("Set MACAROK_FPCALC_PATH to exercise the optional pinned Chromaprint helper.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokChromaprintTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Shell metacharacters remain literal file names; the helper is invoked directly.
        let audio = directory.appendingPathComponent("generated $(touch should-not-exist).wav")
        try wave().write(to: audio)
        let result = try await ChromaprintClient(executableURL: URL(fileURLWithPath: path)).fingerprint(url: audio)
        XCTAssertEqual(result.duration, 16, accuracy: 0.01)
        XCTAssertFalse(result.fingerprint.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("should-not-exist").path))
    }

    private func wave() -> Data {
        let sampleRate = 11_025
        let duration = 16
        let count = sampleRate * duration
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + count * 2)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(count * 2))
        for index in 0..<count {
            let time = Double(index) / Double(sampleRate)
            let frequency = 220 + Double((index / sampleRate) % 5) * 37
            append(Int16((sin(time * frequency * 2 * .pi) * 8_000).rounded()))
        }
        return data
    }
}

private final class AcoustIDFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var captured: URLRequest?
    static var lastRequest: URLRequest? { lock.lock(); defer { lock.unlock() }; return captured }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "acoustid-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            recorded.httpBody = body
        }
        Self.lock.lock(); Self.captured = recorded; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"status":"ok","results":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
