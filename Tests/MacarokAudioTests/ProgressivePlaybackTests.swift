import Foundation
import MacarokAudio
import MacarokCore
import Network
import XCTest

final class ProgressivePlaybackTests: XCTestCase {
    @MainActor
    func testRealHTTPProgressivePlaybackStartsBeforeFullDownloadAndSupportsSegmentSeek() async throws {
        let data = wave(duration: 20, sampleRate: 48_000, channels: 2)
        let server = try ProgressiveHTTPServer(data: data, chunkDelay: 0.12)
        defer { server.stop() }
        let transport = SourceTransport(sourceID: "test.progressive.vlc.\(UUID().uuidString)")
        let stream = BufferedHTTPInputStream(url: server.url, transport: transport,
            bufferBytes: 512 * 1_024, bufferSeconds: 1, durationHint: 20)
        let player = VLCPlaybackEngine()
        player.volume = 0
        defer { player.stop(); stream.close(); transport.invalidate() }
        let completed = expectation(description: "The streamed CUE region reached its end")
        completed.assertForOverFulfill = true
        player.onCompletion = { completed.fulfill() }
        player.load(stream: stream, segmentStart: 5, segmentEnd: 9.2, bufferSeconds: 1, durationHint: 4.2)

        try await eventually(player: player, timeout: 15) { player.state == .playing && player.isSeekable }
        XCTAssertLessThan(server.uniqueBytesDelivered, data.count,
            "VLC must start playback before the HTTP transport has delivered the whole audio file.")
        XCTAssertEqual(stream.snapshot.totalBytes, Int64(data.count))
        XCTAssertEqual(player.duration, 4.2, accuracy: 0.1)
        XCTAssertLessThan(player.position, 3)

        player.pause()
        try await eventually(player: player) { player.state == .paused }
        let paused = player.position
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(player.position, paused, accuracy: 0.15)

        player.seek(to: 3.2)
        player.play()
        await fulfillment(of: [completed], timeout: 12)
        XCTAssertNil(player.lastError)
        XCTAssertNil(stream.streamError)
        XCTAssertEqual(player.position, 4.2, accuracy: 0.1)
        XCTAssertTrue(server.requestedOffsets.contains { $0 > 0 }, "Seeking must request a new HTTP byte range.")
    }

    @MainActor
    private func eventually(player: VLCPlaybackEngine, timeout: TimeInterval = 8,
                            _ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            if player.state == .failed { throw ProgressiveTestError.failed(player.lastError ?? "VLC failed") }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ProgressiveTestError.failed("Timed out waiting for VLC; state: \(player.state), position: \(player.position)")
    }

    private func wave(duration: Int, sampleRate: Int, channels: Int) -> Data {
        let byteCount = duration * sampleRate * channels * 2
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + byteCount)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(channels)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * channels * 2)); append(UInt16(channels * 2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(byteCount)); data.append(Data(repeating: 0, count: byteCount))
        return data
    }
}

private enum ProgressiveTestError: Error { case failed(String) }

/// A real TCP fixture: URLSession and libVLC share no test-only networking hooks.
private final class ProgressiveHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MacarokTests.ProgressiveHTTPServer")
    private let lock = NSLock()
    private let data: Data
    private let chunkDelay: TimeInterval
    private var connections: [UUID: NWConnection] = [:]
    private var servedRanges: [Range<Int>] = []
    private var offsets: [Int] = []
    private var isStopped = false
    let url: URL

    init(data: Data, chunkDelay: TimeInterval) throws {
        self.data = data; self.chunkDelay = chunkDelay
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        // Network.framework requires a connection handler before starting.
        // The fixture URL is not exposed until the real handler is installed.
        listener.newConnectionHandler = { $0.cancel() }
        let startup = ListenerStartup()
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready:
                if let port = listener.port { startup.complete(.success(port.rawValue)) }
            case .failed(let error): startup.complete(.failure(error))
            default: break
            }
        }
        listener.start(queue: queue)
        guard startup.ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw ProgressiveTestError.failed("The loopback HTTP fixture did not start.")
        }
        let port = try startup.result!.get()
        listener.stateUpdateHandler = nil
        url = URL(string: "http://127.0.0.1:\(port)/album.wav")!
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    var requestedOffsets: [Int] { lock.lock(); defer { lock.unlock() }; return offsets }

    var uniqueBytesDelivered: Int {
        lock.lock(); defer { lock.unlock() }
        var count = 0
        var lastEnd = 0
        for range in servedRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            count += max(0, range.upperBound - max(lastEnd, range.lowerBound))
            lastEnd = max(lastEnd, range.upperBound)
        }
        return count
    }

    func stop() {
        lock.lock()
        guard !isStopped else { lock.unlock(); return }
        isStopped = true
        let pending = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        listener.cancel()
        pending.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        lock.lock(); connections[id] = connection; lock.unlock()
        connection.start(queue: queue)
        receive(connection, id: id, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1_024) { [weak self] bytes, _, complete, error in
            guard let self else { return }
            var request = accumulated
            if let bytes { request.append(bytes) }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection, id: id, request: String(decoding: request, as: UTF8.self))
            } else if error != nil || complete || request.count > 32 * 1_024 {
                self.close(connection, id: id)
            } else { self.receive(connection, id: id, accumulated: request) }
        }
    }

    private func respond(_ connection: NWConnection, id: UUID, request: String) {
        let rangeHeader = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }
        let offset = rangeHeader.flatMap { line in
            line.range(of: "bytes=", options: .caseInsensitive).flatMap { Int(line[$0.upperBound...].split(separator: "-").first ?? "0") }
        } ?? 0
        lock.lock(); offsets.append(offset); lock.unlock()
        guard offset >= 0, offset < data.count else {
            let header = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(data.count)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in self?.close(connection, id: id) })
            return
        }
        let status = rangeHeader == nil ? "200 OK" : "206 Partial Content"
        var header = "HTTP/1.1 \(status)\r\nContent-Type: audio/wav\r\nAccept-Ranges: bytes\r\nContent-Length: \(data.count - offset)\r\nConnection: close\r\n"
        if rangeHeader != nil { header += "Content-Range: bytes \(offset)-\(data.count - 1)/\(data.count)\r\n" }
        header += "\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return }
            self.send(connection, id: id, offset: offset)
        })
    }

    private func send(_ connection: NWConnection, id: UUID, offset: Int) {
        queue.asyncAfter(deadline: .now() + chunkDelay) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let active = !self.isStopped && self.connections[id] != nil; self.lock.unlock()
            guard active else { return }
            let end = min(offset + 64 * 1_024, self.data.count)
            connection.send(content: self.data.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                guard error == nil else { self.close(connection, id: id); return }
                self.lock.lock(); self.servedRanges.append(offset..<end); self.lock.unlock()
                if end < self.data.count { self.send(connection, id: id, offset: end) }
                else { self.close(connection, id: id) }
            })
        }
    }

    private func close(_ connection: NWConnection, id: UUID) {
        lock.lock(); connections.removeValue(forKey: id); lock.unlock()
        connection.cancel()
    }

    private final class ListenerStartup: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private(set) var result: Result<UInt16, Error>?
        func complete(_ value: Result<UInt16, Error>) {
            lock.lock(); defer { lock.unlock() }
            guard result == nil else { return }
            result = value; ready.signal()
        }
    }
}
