import Foundation
import VLCKit
import XCTest
@testable import MacarokAudio

final class PlaybackEventQueueTests: XCTestCase {
    @MainActor
    func testTimeDiscontinuitiesAndRapidPlayerRetirementStayOffNativeCallbackStacks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokEventRetirement-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("retirement.wav")
        try wave().write(to: url)
        // Construction installs the event policy before even the first VLCMedia is created.
        let bootstrap = VLCPlaybackEngine()
        defer { bootstrap.stop() }
        let configuration = try XCTUnwrap(VLCLibrary.sharedEventsConfiguration)
        XCTAssertTrue(configuration.isAsync())
        let queue = try XCTUnwrap(configuration.dispatchQueue())
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        defer { queue.setSpecific(key: key, value: nil) }
        let trace = EventTrace()
        let stateObserver = NotificationCenter.default.addObserver(forName: VLCMediaPlayer.stateChangedNotification,
            object: nil, queue: nil) { notification in
                guard let player = notification.object as? VLCMediaPlayer else { return }
                trace.record(player, state: true, configuredQueue: DispatchQueue.getSpecific(key: key) == true,
                             mainThread: Thread.isMainThread)
            }
        let timeObserver = NotificationCenter.default.addObserver(forName: VLCMediaPlayer.timeChangedNotification,
            object: nil, queue: nil) { notification in
                guard let player = notification.object as? VLCMediaPlayer else { return }
                trace.record(player, state: false, configuredQueue: DispatchQueue.getSpecific(key: key) == true,
                             mainThread: Thread.isMainThread)
            }
        defer {
            NotificationCenter.default.removeObserver(stateObserver)
            NotificationCenter.default.removeObserver(timeObserver)
        }

        let iterations = 6
        for _ in 0..<iterations {
            var engine: VLCPlaybackEngine? = VLCPlaybackEngine()
            weak var releasedEngine = engine
            engine?.volume = 0
            engine?.load(url: url, bufferSeconds: 0.05)
            try await eventually { engine?.state == .playing && (engine?.position ?? 0) > 0.05 }
            XCTAssertTrue(engine?.setUpcoming(token: UUID(), url: url) == true)
            let selected = UUID()
            let stream = try XCTUnwrap(InputStream(url: url))
            XCTAssertTrue(engine?.setUpcoming(token: selected, stream: stream, segmentStart: 1, segmentEnd: 7,
                                              bufferSeconds: 0.05, supportsSeeking: { true }) == true)
            XCTAssertTrue(engine?.playUpcoming(token: selected) == true)
            try await eventually { engine?.state == .playing && (engine?.position ?? 0) > 0.05 }
            engine?.pause()
            try await eventually { engine?.state == .paused }
            // Stop/drop immediately after the discontinuity, then create the following player.
            // The old failure released VLCMediaPlayer from a notification's native callback pool.
            autoreleasepool { engine?.stop(); engine = nil }
            XCTAssertNil(releasedEngine)
        }

        try await eventually { trace.snapshot.alivePlayers == 0 }
        let result = trace.snapshot
        XCTAssertGreaterThanOrEqual(result.players, iterations * 2)
        XCTAssertGreaterThan(result.stateEvents, 0)
        XCTAssertGreaterThan(result.queuedTimeEvents, 0,
                             "Pause/stop discontinuity notifications must actually execute on the configured queue.")
        XCTAssertEqual(result.wrongQueueEvents, 0,
                       "State callbacks and non-main time callbacks must never execute inline under native player/timer locks.")
        XCTAssertEqual(result.alivePlayers, 0, "The policy must release retired players rather than retain a growing pool.")
    }

    @MainActor
    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure.timeout
    }

    private enum Failure: Error { case timeout }

    private final class EventTrace: @unchecked Sendable {
        private final class WeakPlayer {
            weak var value: VLCMediaPlayer?
            init(_ player: VLCMediaPlayer) { value = player }
        }
        private let lock = NSLock()
        private var players: [WeakPlayer] = []
        private var stateEvents = 0, queuedTimeEvents = 0, wrongQueueEvents = 0

        func record(_ player: VLCMediaPlayer, state: Bool, configuredQueue: Bool, mainThread: Bool) {
            lock.lock(); defer { lock.unlock() }
            if !players.contains(where: { $0.value === player }) { players.append(WeakPlayer(player)) }
            if state {
                stateEvents += 1
                if !configuredQueue { wrongQueueEvents += 1 }
            } else if configuredQueue { queuedTimeEvents += 1 }
            else if !mainThread { wrongQueueEvents += 1 }
        }

        var snapshot: (players: Int, alivePlayers: Int, stateEvents: Int, queuedTimeEvents: Int, wrongQueueEvents: Int) {
            lock.lock(); defer { lock.unlock() }
            return (players.count, players.filter { $0.value != nil }.count, stateEvents, queuedTimeEvents, wrongQueueEvents)
        }
    }

    private func wave() -> Data {
        let sampleRate = 8_000, size = 8 * sampleRate * 2
        var data = Data("RIFF".utf8)
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        word(UInt32(size + 36)); data.append(Data("WAVEfmt ".utf8)); word(UInt32(16))
        word(UInt16(1)); word(UInt16(1)); word(UInt32(sampleRate)); word(UInt32(sampleRate * 2))
        word(UInt16(2)); word(UInt16(16)); data.append(Data("data".utf8)); word(UInt32(size)); data.append(Data(count: size))
        return data
    }
}
