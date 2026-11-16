import Combine
import Foundation
import MacarokAudio
import MacarokCore
import Network
import XCTest

final class ProgressivePlaybackTests: XCTestCase {
    @MainActor
    func testHTTPAndLivePlaybackContinueDuringBackgroundCatalogWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokAudioStress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for live in [false, true] {
            let server = try ProgressiveHTTPServer(data: wave(duration: 20, sampleRate: 48_000, channels: 2), chunkDelay: 0.06)
            defer { server.stop() }
            let transport = SourceTransport(sourceID: "test.stress.vlc.\(UUID().uuidString)")
            let stream = BufferedHTTPInputStream(url: server.url, transport: transport,
                bufferBytes: 512 * 1024, bufferSeconds: 1, durationHint: live ? nil : 20, live: live)
            let player = VLCPlaybackEngine()
            player.volume = 0
            defer { player.stop(); stream.close(); transport.invalidate() }
            player.load(stream: stream, bufferSeconds: 1, durationHint: live ? nil : 20, live: live,
                        supportsSeeking: { stream.supportsSeeking })
            try await eventually(player: player, timeout: 15) { player.state == .playing && player.position > 0.2 }
            let initialPosition = player.position
            var beats = 0
            var lastBeat = ProcessInfo.processInfo.systemUptime
            var largestBeatGap: TimeInterval = 0
            let heartbeat = Timer(timeInterval: 0.02, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let now = ProcessInfo.processInfo.systemUptime
                    largestBeatGap = max(largestBeatGap, now - lastBeat)
                    lastBeat = now; beats += 1
                }
            }
            RunLoop.main.add(heartbeat, forMode: .common)
            defer { heartbeat.invalidate() }
            let databaseURL = directory.appendingPathComponent(live ? "live.sqlite" : "http.sqlite")
            let importedCount = try await Task.detached(priority: .utility) {
                let store = try LibraryStore(url: databaseURL)
                let source = SourceRecord(id: "stress", kind: .openSubsonic, name: "Synthetic import", location: "https://music.invalid")
                try store.saveSource(source)
                let tracks = (0..<4_000).map { index in
                    TrackRecord(id: "stress-\(index)", sourceID: source.id, title: "Track \(4_000 - index)",
                                artist: "Artist \(index % 100)", album: "Album \(index / 10)", duration: 180)
                }
                let deadline = ProcessInfo.processInfo.systemUptime + 1.4
                repeat {
                    try store.replaceSourceTracks(sourceID: source.id, with: tracks)
                    // Exercise the same Foundation comparison work as background library snapshots.
                    _ = try store.tracks(sourceID: source.id, ordered: false).sorted {
                        $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    }
                } while ProcessInfo.processInfo.systemUptime < deadline
                return try store.tracks(sourceID: source.id, ordered: false).count
            }.value
            XCTAssertEqual(importedCount, 4_000)
            XCTAssertGreaterThan(beats, 15, "The foreground heartbeat must keep running during catalog writes and sorting.")
            XCTAssertLessThan(largestBeatGap, 0.75, "Background work must not monopolize the foreground executor.")
            XCTAssertGreaterThan(player.position, initialPosition + 0.6,
                                 live ? "Live radio must keep decoding during an import." : "HTTP playback must keep decoding during an import.")
            XCTAssertEqual(player.state, .playing)
            XCTAssertNil(player.lastError)
            XCTAssertNil(stream.streamError)
        }
    }

    @MainActor
    func testVariableBitratePodcastSeeksToSettledPlaybackWithAnInaccurateRSSDuration() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "variable-bitrate-podcast.mp3", withExtension: nil,
                                                  subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let server = try ProgressiveHTTPServer(data: data, chunkDelay: 0.08,
                                               contentType: "audio/mpeg", path: "/podcast.mp3")
        defer { server.stop() }
        let transport = SourceTransport(sourceID: "test.podcast.vlc.\(UUID().uuidString)")
        // A deliberately wrong RSS value must not determine the HTTP buffering target or replace
        // the duration decoded from the VBR headers. Only the engine receives the initial UI hint.
        let stream = BufferedHTTPInputStream(url: server.url, transport: transport,
            bufferBytes: 256 * 1024, bufferSeconds: 1, durationHint: nil)
        let player = VLCPlaybackEngine()
        player.volume = 0
        defer { player.stop(); stream.close(); transport.invalidate() }
        player.load(stream: stream, bufferSeconds: 1, durationHint: 1, supportsSeeking: { stream.supportsSeeking })
        player.seek(to: 40)
        XCTAssertEqual(player.position, 40, accuracy: 0.01,
                       "A pending resume point must not be truncated to the unverified RSS duration.")
        try await eventually(player: player, timeout: 15) {
            player.state == .playing && player.isSeekable && player.duration > 120 && player.position > 40.5
        }
        XCTAssertEqual(player.duration, 128, accuracy: 0.5)
        XCTAssertLessThan(player.position, 43)

        var positions: [Double] = []
        let observation = player.timeline.$position.sink { positions.append($0) }
        defer { observation.cancel() }
        positions.removeAll()
        player.seek(to: 80)
        XCTAssertEqual(player.position, 80, accuracy: 0.01)
        // Reaching a later timestamp, rather than merely the optimistic target, proves VLC resumed
        // actual decoding at the requested point and acknowledged the seek.
        try await eventually(player: player) { player.state == .playing && player.position > 80.5 }
        XCTAssertLessThan(player.position, 83)
        XCTAssertTrue(positions.allSatisfy { $0 >= 79.5 }, "Cached pre-seek times must not move the cursor backward.")

        player.pause()
        try await eventually(player: player) { player.state == .paused }
        player.seek(to: 17.5)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(player.position, 17.5, accuracy: 0.2)
        player.play()
        try await eventually(player: player) { player.state == .playing && player.position > 18 }
        XCTAssertLessThan(player.position, 20.5)
        XCTAssertEqual(stream.supportsSeeking, true)
        XCTAssertNil(player.lastError)
        XCTAssertNil(stream.streamError)

        player.stop(); stream.close()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(player.state, .stopped)
        XCTAssertEqual(player.position, 0)
        XCTAssertFalse(player.isSeekable)
    }

    @MainActor
    func testPodcastWithoutByteRangesRejectsPendingAndLaterSeeksWithoutFreezingPlayback() async throws {
        let server = try ProgressiveHTTPServer(data: wave(duration: 8, sampleRate: 48_000, channels: 2),
                                               chunkDelay: 0.03, supportsRanges: false)
        defer { server.stop() }
        let transport = SourceTransport(sourceID: "test.podcast.unseekable.\(UUID().uuidString)")
        let stream = BufferedHTTPInputStream(url: server.url, transport: transport,
            bufferBytes: 256 * 1024, bufferSeconds: 1)
        let player = VLCPlaybackEngine()
        player.volume = 0
        defer { player.stop(); stream.close(); transport.invalidate() }
        XCTAssertNil(stream.supportsSeeking)
        player.load(stream: stream, bufferSeconds: 1, durationHint: 8,
                    supportsSeeking: { stream.supportsSeeking })
        player.seek(to: 6)
        try await eventually(player: player, timeout: 15) {
            player.state == .playing && player.position > 0.2 && player.position < 2 && !player.isSeekable
        }
        XCTAssertEqual(stream.supportsSeeking, false)
        let before = player.position
        player.seek(to: 6)
        XCTAssertEqual(player.position, before, accuracy: 0.01)
        try await eventually(player: player) { player.position > before + 0.5 }
        XCTAssertLessThan(player.position, 3)

        player.pause()
        try await eventually(player: player) { player.state == .paused }
        let paused = player.position
        player.seek(to: 7)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(player.position, paused, accuracy: 0.15)
        player.play()
        try await eventually(player: player) { player.state == .playing && player.position > paused + 0.4 }
        XCTAssertFalse(player.isSeekable)
        XCTAssertEqual(server.requestedOffsets, [0], "Unsupported seeks must not restart the HTTP transfer.")
        XCTAssertNil(player.lastError)
        XCTAssertNil(stream.streamError)
    }

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

    /// VLCKit gives libVLC an unknown size for every NSInputStream, so these demuxers cannot seek
    /// through BufferedHTTPInputStream. The application hands their URLs to libVLC directly.
    @MainActor
    func testFLACAndOggSeekWhenLibVLCOpensTheHTTPURL() async throws {
        for (name, type) in [("seekable-silence.flac", "audio/flac"), ("seekable-silence.ogg", "audio/ogg")] {
            let fixture = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
            let server = try ProgressiveHTTPServer(data: Data(contentsOf: fixture), chunkDelay: 0, contentType: type, path: "/\(name)")
            defer { server.stop() }
            let player = VLCPlaybackEngine()
            player.volume = 0
            defer { player.stop() }
            player.load(url: server.url, bufferSeconds: 1, durationHint: 40)
            try await eventually(player: player, timeout: 15) { player.state == .playing && player.isSeekable }
            player.seek(to: 25)
            try await eventually(player: player, timeout: 10) { player.position > 25.3 }
            XCTAssertLessThan(player.position, 32, "\(name) must continue from the requested position.")
            XCTAssertNil(player.lastError)
        }
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
    private let contentType: String
    private let supportsRanges: Bool
    private var connections: [UUID: NWConnection] = [:]
    private var servedRanges: [Range<Int>] = []
    private var offsets: [Int] = []
    private var isStopped = false
    let url: URL

    init(data: Data, chunkDelay: TimeInterval, contentType: String = "audio/wav", path: String = "/album.wav",
         supportsRanges: Bool = true) throws {
        self.data = data; self.chunkDelay = chunkDelay; self.contentType = contentType
        self.supportsRanges = supportsRanges
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
        url = URL(string: "http://127.0.0.1:\(port)\(path)")!
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
        let offset = (supportsRanges ? rangeHeader : nil).flatMap { line in
            line.range(of: "bytes=", options: .caseInsensitive).flatMap { Int(line[$0.upperBound...].split(separator: "-").first ?? "0") }
        } ?? 0
        lock.lock(); offsets.append(offset); lock.unlock()
        guard offset >= 0, offset < data.count else {
            let header = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(data.count)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in self?.close(connection, id: id) })
            return
        }
        let partial = supportsRanges && rangeHeader != nil
        let status = partial ? "206 Partial Content" : "200 OK"
        var header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nAccept-Ranges: \(supportsRanges ? "bytes" : "none")\r\nContent-Length: \(data.count - offset)\r\nConnection: close\r\n"
        if partial { header += "Content-Range: bytes \(offset)-\(data.count - 1)/\(data.count)\r\n" }
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
