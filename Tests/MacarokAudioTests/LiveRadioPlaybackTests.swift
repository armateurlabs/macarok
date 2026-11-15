import Foundation
import MacarokAudio
import XCTest

@MainActor
final class LiveRadioPlaybackTests: XCTestCase {
    func testLivePlaybackDisablesFileSeekingAndPauseClosesTheBroadcastConnection() async throws {
        let first = RadioTrackingInputStream(data: wave(seconds: 20))
        let second = RadioTrackingInputStream(data: wave(seconds: 20))
        let player = VLCPlaybackEngine()
        player.volume = 0
        var completions = 0
        player.onCompletion = { completions += 1 }
        defer { player.stop(); first.close(); second.close() }
        player.load(stream: first, bufferSeconds: 1, durationHint: 20, live: true)
        try await eventually(player) { player.state == .playing && player.position > 0.1 }
        XCTAssertFalse(player.isSeekable, "Live mode stays unseekable even when the synthetic WAV exposes file offsets.")
        XCTAssertEqual(player.duration, 0)
        let beforeSeek = player.position
        player.seek(to: 15)
        XCTAssertEqual(player.position, beforeSeek, accuracy: 0.001)
        let previousCloses = first.closeCount
        player.pauseLive()
        XCTAssertGreaterThan(first.closeCount, previousCloses)
        XCTAssertEqual(player.state, .paused)
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(player.duration, 0)
        XCTAssertFalse(player.isSeekable)
        XCTAssertEqual(completions, 0, "Pausing radio must not advance the queue as if a finite track ended.")

        // Reconnection installs a fresh input. Old VLC stop callbacks must not change the new session.
        player.load(stream: second, bufferSeconds: 1, live: true)
        try await eventually(player) { player.state == .playing && player.position > 0.1 }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(player.state, .playing)
        XCTAssertFalse(player.isSeekable)
        XCTAssertEqual(player.duration, 0)
        XCTAssertEqual(completions, 0)
        XCTAssertNil(player.lastError)
    }

    private func eventually(_ player: VLCPlaybackEngine, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if condition() { return }
            if player.state == .failed { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Live VLC playback did not reach the expected state: \(player.state), \(player.lastError ?? "no error")")
        throw URLError(.timedOut)
    }

    private func wave(seconds: Int) -> Data {
        let sampleRate = 16_000, byteCount = seconds * sampleRate * 2
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + byteCount)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(byteCount)); data.append(Data(repeating: 0, count: byteCount))
        return data
    }
}

private final class RadioTrackingInputStream: InputStream, @unchecked Sendable {
    private let backing: InputStream
    private let length: Int
    private let lock = NSLock()
    private var closes = 0
    override init(data: Data) { backing = InputStream(data: data); length = data.count; super.init(data: Data()) }
    var closeCount: Int { lock.lock(); defer { lock.unlock() }; return closes }
    override func open() { backing.open() }
    override func close() { lock.lock(); closes += 1; lock.unlock(); backing.close() }
    override var streamStatus: Stream.Status { backing.streamStatus }
    override var streamError: Error? { backing.streamError }
    override var hasBytesAvailable: Bool { backing.hasBytesAvailable }
    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int { backing.read(buffer, maxLength: len) }
    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>) -> Bool { false }
    override func property(forKey key: Stream.PropertyKey) -> Any? {
        if key.rawValue == "NSStreamFileSizeKey" { return NSNumber(value: length) }
        return backing.property(forKey: key)
    }
    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool { backing.setProperty(property, forKey: key) }
    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
}
