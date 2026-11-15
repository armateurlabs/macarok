import XCTest
import Foundation
import Security
import Darwin
@testable import MacarokCore

final class CertificatePolicyTests: XCTestCase {
    func testDedicatedPlaybackChunksAndDownloadsShareExplicitCertificateTrust() async throws {
        let fixture = try CertificateFixture(host: "localhost")
        let server = try LocalTLSServer(certificate: fixture)
        defer { server.stop() }
        let suite = "MacarokTransferTLS.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CertificateTrustStore(defaults: defaults)
        let probe = ApprovalProbe(accept: true)
        let transport = SourceTransport(sourceID: "chunked", certificateStore: store, certificateApproval: { probe.record($0) })
        defer { transport.invalidate() }
        let received = try await playbackData(transport, from: server.url)
        XCTAssertEqual(received.count, 262_144)
        XCTAssertEqual(probe.count, 1)

        let progress = TransferProgressProbe()
        let destination = fixture.directory.appendingPathComponent("downloaded.flac")
        let saved = try await transport.download(from: server.url, to: destination, progress: { progress.record($0, $1) })
        XCTAssertEqual(saved, destination)
        XCTAssertEqual(try Data(contentsOf: saved), received)
        XCTAssertEqual(progress.last?.0, 262_144)
        XCTAssertEqual(progress.last?.1, 262_144)
        XCTAssertEqual(probe.count, 1, "The playback and download sessions must honor the same accepted leaf pin.")

        let other = SourceTransport(sourceID: "other", certificateStore: store)
        defer { other.invalidate() }
        do { _ = try await playbackData(other, from: server.url); XCTFail("A separate playback session must retain source-specific certificate isolation.") }
        catch { XCTAssertTrue(error is URLError) }
    }

    func testCancelledDownloadDoesNotReplaceAnExistingDestination() async throws {
        let fixture = try CertificateFixture(host: "localhost")
        let server = try LocalTLSServer(certificate: fixture)
        defer { server.stop() }
        let transport = SourceTransport(sourceID: UUID().uuidString, certificateApproval: { _ in true })
        defer { transport.invalidate() }
        let destination = fixture.directory.appendingPathComponent("kept.flac")
        let original = Data("An existing download".utf8)
        try original.write(to: destination)
        let rejected = server.url.deletingLastPathComponent().appendingPathComponent("error.flac")
        do { _ = try await transport.download(from: rejected, to: destination); XCTFail("HTTP error bodies must not replace audio files.") }
        catch SourceNetworkError.httpStatus(let status) { XCTAssertEqual(status, 503) }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        let progress = expectation(description: "The download received an initial chunk")
        progress.assertForOverFulfill = false
        let slow = server.url.deletingLastPathComponent().appendingPathComponent("slow.flac")
        let download = Task { try await transport.download(from: slow, to: destination, progress: { _, _ in progress.fulfill() }) }
        await fulfillment(of: [progress], timeout: 5)
        download.cancel()
        do { _ = try await download.value; XCTFail("Cancellation must not publish a complete download.") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    private func playbackData(_ transport: SourceTransport, from url: URL) async throws -> Data {
        let received = TransferDataProbe()
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let task = try transport.startPlaybackStream(for: URLRequest(url: url), onResponse: { _ in },
                    onData: { received.append($0) }, onComplete: { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: received.data) }
                    })
                task.resume()
            } catch { continuation.resume(throwing: error) }
        }
    }

    func testLiveHTTPSDataAndProgressiveBytesShareExplicitCertificateTrust() async throws {
        let fixture = try CertificateFixture(host: "localhost")
        let server = try LocalTLSServer(certificate: fixture)
        defer { server.stop() }
        let suite = "MacarokLiveTLS.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CertificateTrustStore(defaults: defaults)
        let probe = ApprovalProbe(accept: true)
        let transport = SourceTransport(sourceID: "live", certificateStore: store, certificateApproval: { probe.record($0) })
        defer { transport.invalidate() }
        let data = try await transport.data(from: server.url)
        XCTAssertEqual(data.count, 262_144)
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(probe.last?.host, "localhost")
        XCTAssertEqual(probe.last?.port, server.url.port)

        let reconnect = SourceTransport(sourceID: "live", certificateStore: CertificateTrustStore(defaults: defaults))
        defer { reconnect.invalidate() }
        var request = URLRequest(url: server.url)
        request.setValue("bytes=65536-", forHTTPHeaderField: "Range")
        let (bytes, response) = try await reconnect.bytes(for: request)
        defer { bytes.task.cancel() }
        XCTAssertEqual(response.statusCode, 206)
        var received = Data()
        for try await byte in bytes { received.append(byte) }
        XCTAssertEqual(received.count, 196_608)
        XCTAssertEqual(received, data.dropFirst(65_536))

        let otherSource = SourceTransport(sourceID: "other", certificateStore: store)
        defer { otherSource.invalidate() }
        do { _ = try await otherSource.data(from: server.url); XCTFail("A different source must not inherit trust.") }
        catch { XCTAssertTrue(error is URLError) }
    }

    func testUnknownSelfSignedCertificateRequiresExplicitApprovalAndPersistsThePin() async throws {
        let fixture = try CertificateFixture()
        let suite = "MacarokTLS.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CertificateTrustStore(defaults: defaults)
        let probe = ApprovalProbe(accept: true)
        let transport = SourceTransport(sourceID: "one", certificateStore: store, certificateApproval: { probe.record($0) })
        defer { transport.invalidate() }

        let first = await disposition(transport, trust: try fixture.trust(), host: fixture.host)
        XCTAssertEqual(first, .useCredential)
        XCTAssertEqual(probe.count, 1)
        let fingerprint = CertificateTrustStore.fingerprint(for: fixture.der)
        XCTAssertEqual(store.trustedFingerprint(sourceID: "one", host: fixture.host, port: 443), fingerprint)

        let reloadedStore = CertificateTrustStore(defaults: defaults)
        let reconnect = SourceTransport(sourceID: "one", certificateStore: reloadedStore)
        defer { reconnect.invalidate() }
        let reconnectResult = await disposition(reconnect, trust: try fixture.trust(), host: fixture.host)
        XCTAssertEqual(reconnectResult, .useCredential)
        let otherSource = SourceTransport(sourceID: "two", certificateStore: reloadedStore)
        defer { otherSource.invalidate() }
        let otherResult = await disposition(otherSource, trust: try fixture.trust(), host: fixture.host)
        XCTAssertEqual(otherResult, .cancelAuthenticationChallenge)
    }

    func testCertificateChangePromptsAgainAndCanBeDeclined() async throws {
        let old = try CertificateFixture()
        let changed = try CertificateFixture(host: old.host)
        let suite = "MacarokTLS.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CertificateTrustStore(defaults: defaults)
        let oldFingerprint = CertificateTrustStore.fingerprint(for: old.der)
        store.trust(oldFingerprint, sourceID: "one", host: old.host, port: 443)
        let probe = ApprovalProbe(accept: false)
        let transport = SourceTransport(sourceID: "one", certificateStore: store, certificateApproval: { probe.record($0) })
        defer { transport.invalidate() }
        let result = await disposition(transport, trust: try changed.trust(), host: changed.host)
        XCTAssertEqual(result, .cancelAuthenticationChallenge)
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(probe.last?.previouslyTrustedFingerprint, oldFingerprint)
        XCTAssertEqual(store.trustedFingerprint(sourceID: "one", host: old.host, port: 443), oldFingerprint)
    }

    func testHostnameAndValidityAreCheckedBeforeOfferingTrust() async throws {
        let fixture = try CertificateFixture()
        let probe = ApprovalProbe(accept: true)
        let transport = SourceTransport(sourceID: "invalid", certificateApproval: { probe.record($0) })
        defer { transport.invalidate() }
        let wrongHost = await disposition(transport, trust: try fixture.trust(host: "other.test"), host: "other.test")
        XCTAssertEqual(wrongHost, .cancelAuthenticationChallenge)
        let expired = try fixture.trust()
        SecTrustSetVerifyDate(expired, Date().addingTimeInterval(20 * 24 * 3600) as CFDate)
        let expiredResult = await disposition(transport, trust: expired, host: fixture.host)
        XCTAssertEqual(expiredResult, .cancelAuthenticationChallenge)
        XCTAssertEqual(probe.count, 0)
    }

    func testNormallyTrustedCertificateDoesNotPrompt() async throws {
        let fixture = try CertificateFixture()
        let trust = try fixture.trust()
        let certificate = SecCertificateCreateWithData(nil, fixture.der as CFData)!
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        XCTAssertTrue(SecTrustEvaluateWithError(trust, nil))
        let probe = ApprovalProbe(accept: false)
        let transport = SourceTransport(sourceID: "normal", certificateApproval: { probe.record($0) })
        defer { transport.invalidate() }
        let result = await disposition(transport, trust: trust, host: fixture.host)
        XCTAssertEqual(result, .performDefaultHandling)
        XCTAssertEqual(probe.count, 0)
    }

    private func disposition(_ transport: SourceTransport, trust: SecTrust, host: String) async -> URLSession.AuthChallengeDisposition {
        let protection = TestProtectionSpace(trust: trust, host: host)
        let challenge = URLAuthenticationChallenge(protectionSpace: protection, proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: ChallengeSender())
        return await withCheckedContinuation { continuation in
            transport.urlSession(URLSession.shared, didReceive: challenge) { disposition, _ in continuation.resume(returning: disposition) }
        }
    }
}

private final class TransferDataProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
}

private final class TransferProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Int64, Int64?)?
    var last: (Int64, Int64?)? { lock.lock(); defer { lock.unlock() }; return value }
    func record(_ received: Int64, _ expected: Int64?) { lock.lock(); value = (received, expected); lock.unlock() }
}

private final class ApprovalProbe: @unchecked Sendable {
    let accept: Bool
    private let lock = NSLock()
    private var requests: [ServerCertificateChallenge] = []
    init(accept: Bool) { self.accept = accept }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    var last: ServerCertificateChallenge? { lock.lock(); defer { lock.unlock() }; return requests.last }
    func record(_ request: ServerCertificateChallenge) -> Bool {
        lock.lock(); requests.append(request); lock.unlock(); return accept
    }
}

private final class TestProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    let testTrust: SecTrust
    override var serverTrust: SecTrust? { testTrust }
    init(trust: SecTrust, host: String) {
        testTrust = trust
        super.init(host: host, port: 443, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }
    required init?(coder: NSCoder) { fatalError("Not used by certificate policy tests") }
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

private final class CertificateFixture {
    let host: String
    let directory: URL
    let der: Data

    init(host: String = "music.test") throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else { throw XCTSkip("OpenSSL is required to generate a short-lived test certificate.") }
        self.host = host
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokTLS-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["req", "-x509", "-newkey", "rsa:3072", "-sha256", "-nodes", "-days", "3",
            "-keyout", directory.appendingPathComponent("key.pem").path, "-out", directory.appendingPathComponent("certificate.der").path, "-outform", "DER",
            "-subj", "/CN=\(host)", "-addext", "subjectAltName=DNS:\(host)", "-addext", "basicConstraints=critical,CA:FALSE",
            "-addext", "extendedKeyUsage=serverAuth", "-addext", "keyUsage=critical,digitalSignature,keyEncipherment"]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("OpenSSL cannot generate the certificate fixture on this machine.") }
        der = try Data(contentsOf: directory.appendingPathComponent("certificate.der"))
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func trust(host: String? = nil) throws -> SecTrust {
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, (host ?? self.host) as CFString), &trust)
        guard status == errSecSuccess, let trust else { throw SourceNetworkError.keychain(status) }
        SecTrustSetNetworkFetchAllowed(trust, false)
        return trust
    }
}

private final class LocalTLSServer {
    let process: Process
    let url: URL
    private let terminationSignal: DispatchSemaphore
    private let stopLock = NSLock()
    private var didStop = false

    init(certificate: CertificateFixture) throws {
        let pem = certificate.directory.appendingPathComponent("certificate.pem")
        let conversion = Process()
        conversion.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        conversion.arguments = ["x509", "-inform", "DER", "-in", certificate.directory.appendingPathComponent("certificate.der").path, "-out", pem.path]
        conversion.standardOutput = Pipe(); conversion.standardError = Pipe()
        try conversion.run(); conversion.waitUntilExit()
        guard conversion.terminationStatus == 0 else { throw XCTSkip("Could not prepare the HTTPS test certificate.") }
        let portFile = certificate.directory.appendingPathComponent("port")
        let script = """
        import http.server, ssl, sys, time
        from pathlib import Path
        payload = bytes(range(256)) * 1024
        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def do_GET(self):
                value = self.headers.get('Range', 'bytes=0-')
                offset = int(value.split('=')[1].split('-')[0])
                self.send_response(503 if self.path == '/error.flac' else 206 if 'Range' in self.headers else 200)
                self.send_header('Content-Length', str(len(payload) - offset))
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('Content-Type', 'audio/flac')
                if 'Range' in self.headers:
                    self.send_header('Content-Range', f'bytes {offset}-{len(payload)-1}/{len(payload)}')
                self.end_headers()
                for index in range(offset, len(payload), 65536):
                    self.wfile.write(payload[index:index+65536]); self.wfile.flush(); time.sleep(0.3 if self.path == '/slow.flac' else 0.02)
            def log_message(self, *args):
                pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        server.daemon_threads = True
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(sys.argv[1], sys.argv[2])
        server.socket = context.wrap_socket(server.socket, server_side=True)
        Path(sys.argv[3]).write_text(str(server.server_port))
        server.serve_forever()
        """
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", script, pem.path, certificate.directory.appendingPathComponent("key.pem").path, portFile.path]
        process.standardOutput = Pipe(); process.standardError = Pipe()
        let signal = DispatchSemaphore(value: 0)
        terminationSignal = signal
        process.terminationHandler = { _ in signal.signal() }
        do { try process.run() }
        catch { Self.terminate(process, signal: signal); throw error }
        var port: Int?
        for _ in 0..<150 {
            if let text = try? String(contentsOf: portFile, encoding: .utf8), let value = Int(text) { port = value; break }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let port else {
            Self.terminate(process, signal: signal)
            throw XCTSkip("Python 3 is required for the live HTTPS fixture.")
        }
        url = URL(string: "https://localhost:\(port)/audio.flac")!
    }

    func stop() {
        stopLock.lock()
        guard !didStop else { stopLock.unlock(); return }
        didStop = true
        stopLock.unlock()
        Self.terminate(process, signal: terminationSignal)
    }

    private static func terminate(_ process: Process, signal: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if signal.wait(timeout: .now() + 1) == .timedOut {
            if process.isRunning, process.processIdentifier > 0 { kill(process.processIdentifier, SIGKILL) }
            _ = signal.wait(timeout: .now() + 1)
        }
    }

    deinit { stop() }
}
