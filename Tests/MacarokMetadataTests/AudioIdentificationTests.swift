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

    func testPublicReferenceResponseRecognizesItsMusicBrainzRecording() throws {
        // Recorded from the official API using a public example fingerprint; no client key,
        // request fingerprint, personal audio, or request headers are included.
        let response = Data(#"""
        {"status":"ok","results":[
          {"id":"9ff43b6a-4f16-427c-93c2-92307ca505e0","score":1,"recordings":[
            {"id":"cd2e7c47-16f5-46c6-a37c-a1eb7bf599ff","title":"Lower Your Eyelids to Die With the Sun",
             "duration":637.333,"artists":[{"name":"M83"}],
             "releasegroups":[{"title":"Donkey Punch"},{"title":"Before the Dawn Heals Us"},{"title":"Café del Mar, Volumen Veinte"}]}]},
          {"id":"be6fa248-97d1-4a18-845b-7c6a070b764c","score":1,"recordings":[
            {"id":"cd2e7c47-16f5-46c6-a37c-a1eb7bf599ff","title":"Lower Your Eyelids to Die With the Sun",
             "duration":637.333,"artists":[{"name":"M83"}],
             "releasegroups":[{"title":"Donkey Punch"},{"title":"Before the Dawn Heals Us"},{"title":"Café del Mar, Volumen Veinte"}]}]}
        ]}
        """#.utf8)
        let matches = try AcoustIDClient.parseResponse(response)
        let match = try XCTUnwrap(matches.first)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(match.recordingID, "cd2e7c47-16f5-46c6-a37c-a1eb7bf599ff")
        XCTAssertEqual(match.title, "Lower Your Eyelids to Die With the Sun")
        XCTAssertEqual(match.artist, "M83")
        XCTAssertTrue(match.albums.contains("Before the Dawn Heals Us"))
    }

    func testLiveAcoustIDReferenceWhenClientKeyIsProvided() async throws {
        guard let key = ProcessInfo.processInfo.environment["MACAROK_ACOUSTID_CLIENT_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw XCTSkip("Set MACAROK_ACOUSTID_CLIENT_KEY to opt in to the live public-reference lookup.")
        }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "acoustid-reference-fingerprint",
                                                     withExtension: "json", subdirectory: "Fixtures"))
        let fingerprint = try JSONDecoder().decode(AudioFingerprint.self, from: Data(contentsOf: fixture))
        let matches = try await AcoustIDClient().lookup(fingerprint, clientKey: key)
        XCTAssertTrue(matches.contains {
            $0.recordingID == "cd2e7c47-16f5-46c6-a37c-a1eb7bf599ff" && $0.artist == "M83"
        }, "The official public reference should identify its expected M83 recording.")
    }

    func testAcoustIDServiceErrorAndEmptyResults() throws {
        XCTAssertThrowsError(try AcoustIDClient.parseResponse(Data(#"{"status":"error","error":{"code":4,"message":"invalid API key"}}"#.utf8))) {
            XCTAssertTrue($0.localizedDescription.contains("invalid API key"))
        }
        XCTAssertEqual(try AcoustIDClient.parseResponse(Data(#"{"status":"ok","results":[]}"#.utf8)), [])
    }

    func testFingerprintWarningIsAdditiveAndRoundTripsWithoutChangingItsFingerprint() throws {
        let legacy = try JSONDecoder().decode(AudioFingerprint.self,
            from: Data(#"{"duration":16,"fingerprint":"AQAB-fingerprint"}"#.utf8))
        XCTAssertNil(legacy.warning)
        let partial = AudioFingerprint(duration: legacy.duration, fingerprint: legacy.fingerprint,
            warning: "Some audio could not be decoded. Identification uses the readable portion of this file.")
        XCTAssertEqual(try JSONDecoder().decode(AudioFingerprint.self, from: JSONEncoder().encode(partial)), partial)
    }

    func testAcoustIDHTTPFailuresKeepStructuredServiceMessagesAndOtherwiseKeepTheirStatus() async throws {
        let cases: [(path: String, status: Int, message: String?)] = [
            ("invalid-key", 400, "invalid API key"),
            ("rate-limited", 429, "too many requests"),
            ("service-error-200", 200, "temporary service error"),
            ("html-error", 503, nil),
            ("malformed-error", 500, nil),
            ("wrong-shaped-error", 500, nil),
            ("false-ok-error", 400, nil)
        ]
        for value in cases {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AcoustIDFixtureProtocol.self]
            let transport = SourceTransport(sourceID: "test.acoustid.\(value.path)", configuration: configuration)
            defer { transport.invalidate() }
            let client = AcoustIDClient(transport: transport,
                endpoint: URL(string: "https://acoustid-fixture.invalid/\(value.path)")!)
            do {
                _ = try await client.lookup(AudioFingerprint(duration: 16, fingerprint: "AQAB-fixture"), clientKey: "fixture-client")
                XCTFail("Expected failure for \(value.path)")
            } catch AudioIdentificationError.service(let message) {
                XCTAssertEqual(message, value.message, value.path)
            } catch SourceNetworkError.httpStatus(let status) {
                XCTAssertNil(value.message, value.path)
                XCTAssertEqual(status, value.status, value.path)
            } catch {
                XCTFail("Unexpected error for \(value.path): \(error)")
            }
        }
    }

    func testDecoderReadWarningRequiresValidBoundedJSONAndOtherHelperFailuresRemainFatal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokFingerprintExitTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("input.wav")
        try Data().write(to: audio)
        let valid = #"{"duration":16,"fingerprint":"AQAB-fixture"}"#
        let warning = "Some audio could not be decoded. Identification uses the readable portion of this file."
        for status in [0, 3] {
            let helper = try makeHelper(in: directory, name: "valid-\(status)", output: valid, termination: "exit \(status)")
            let result = try await ChromaprintClient(executableURL: helper).fingerprint(url: audio)
            XCTAssertEqual(result.duration, 16)
            XCTAssertEqual(result.fingerprint, "AQAB-fixture")
            XCTAssertEqual(result.warning, status == 3 ? warning : nil)
        }
        let failures: [(name: String, output: String, termination: String)] = [
            ("empty-fingerprint-exit", valid, "exit 2"),
            ("other-exit", valid, "exit 1"),
            ("malformed-json", "not JSON", "exit 3"),
            ("missing-fingerprint", #"{"duration":16}"#, "exit 3"),
            ("empty-fingerprint", #"{"duration":16,"fingerprint":""}"#, "exit 3"),
            ("whitespace-fingerprint", #"{"duration":16,"fingerprint":"   "}"#, "exit 3"),
            ("invalid-duration", #"{"duration":0,"fingerprint":"AQAB-fixture"}"#, "exit 3"),
            ("nonfinite-duration", #"{"duration":"NaN","fingerprint":"AQAB-fixture"}"#, "exit 3"),
            ("oversized-fingerprint", "{\"duration\":16,\"fingerprint\":\"" + String(repeating: "A", count: 100_000) + "\"}", "exit 3"),
            ("terminated", valid, "kill -TERM $$")
        ]
        for value in failures {
            let helper = try makeHelper(in: directory, name: value.name, output: value.output, termination: value.termination)
            do {
                _ = try await ChromaprintClient(executableURL: helper).fingerprint(url: audio)
                XCTFail("Expected fingerprint failure for \(value.name)")
            } catch AudioIdentificationError.fingerprintFailed { }
            catch { XCTFail("Unexpected error for \(value.name): \(error)") }
        }
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
        XCTAssertNil(result.warning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("should-not-exist").path))
    }

    func testPinnedHelperKeepsIntactCompressedFingerprintsAndReportsPartialFLACDecoding() async throws {
        guard let path = ProcessInfo.processInfo.environment["MACAROK_FPCALC_PATH"],
              FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("Set MACAROK_FPCALC_PATH to exercise the optional pinned Chromaprint helper.")
        }
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacarokAudioTests/Fixtures", isDirectory: true)
        let client = ChromaprintClient(executableURL: URL(fileURLWithPath: path))
        for (name, duration) in [("seekable-silence.flac", 40.0), ("seekable-silence.ogg", 40.0), ("variable-bitrate-podcast.mp3", 128.0)] {
            let result = try await client.fingerprint(url: fixtures.appendingPathComponent(name))
            XCTAssertEqual(result.duration, duration, accuracy: 0.1, name)
            XCTAssertFalse(result.fingerprint.isEmpty, name)
            XCTAssertNil(result.warning, name)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokPartialFingerprint-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // This checked-in synthetic FLAC prefix reproduces fpcalc 1.6.2's exit 3 with usable JSON.
        let complete = try Data(contentsOf: fixtures.appendingPathComponent("seekable-silence.flac"))
        let damaged = directory.appendingPathComponent("partial.flac")
        try Data(complete.prefix(complete.count * 9 / 10)).write(to: damaged)
        let result = try await client.fingerprint(url: damaged)
        XCTAssertEqual(result.duration, 40, accuracy: 0.1)
        XCTAssertFalse(result.fingerprint.isEmpty)
        XCTAssertEqual(result.warning, "Some audio could not be decoded. Identification uses the readable portion of this file.")
    }

    private func makeHelper(in directory: URL, name: String, output: String, termination: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let quoted = "'" + output.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/sh\nprintf '%s\\n' " + quoted + "\n" + termination + "\n"
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
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
        let status: Int
        let body: Data
        switch request.url?.path {
        case "/invalid-key": status = 400; body = Data(#"{"status":"error","error":{"code":4,"message":"invalid API key"}}"#.utf8)
        case "/rate-limited": status = 429; body = Data(#"{"status":"error","error":{"code":5,"message":"too many requests"}}"#.utf8)
        case "/service-error-200": status = 200; body = Data(#"{"status":"error","error":{"message":"temporary service error"}}"#.utf8)
        case "/html-error": status = 503; body = Data("<html>Service unavailable</html>".utf8)
        case "/malformed-error": status = 500; body = Data("{not valid JSON".utf8)
        case "/wrong-shaped-error": status = 500; body = Data(#"{"status":"error","error":"server unavailable"}"#.utf8)
        case "/false-ok-error": status = 400; body = Data(#"{"status":"ok","results":[]}"#.utf8)
        default: status = 200; body = Data(#"{"status":"ok","results":[]}"#.utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
