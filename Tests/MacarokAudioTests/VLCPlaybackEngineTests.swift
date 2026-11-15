import AppKit
import Foundation
@testable import MacarokAudio
import XCTest

final class VLCPlaybackEngineTests: XCTestCase {
    @MainActor
    func testRequiredCodecsPlayToCompletionThroughPinnedVLC() async throws {
        for name in ["silence.mp3", "silence.flac", "silence.ogg", "silence.opus"] {
            let player = VLCPlaybackEngine()
            player.volume = 0
            let completed = expectation(description: "VLC completed \(name)")
            player.onCompletion = { completed.fulfill() }
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
            player.load(url: url, durationHint: 1.2)
            try await eventually(player: player) { player.state == .playing || player.position > 0 || player.state == .stopped && player.position > 0 }
            await fulfillment(of: [completed], timeout: 10)
            XCTAssertNil(player.lastError, name)
            XCTAssertEqual(player.state, .stopped, name)
            XCTAssertGreaterThan(player.duration, 0.8, name)
        }
    }

    @MainActor
    func testPauseResumeSeekAndCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokPlaybackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("silence.wav")
        try wave(duration: 4).write(to: url)
        let player = VLCPlaybackEngine()
        player.volume = 0
        let complete = expectation(description: "Playback reached the end")
        player.onCompletion = { complete.fulfill() }
        player.load(url: url)
        try await eventually(player: player) { player.state == .playing && player.isSeekable }
        XCTAssertEqual(player.duration, 4, accuracy: 0.1)
        player.pause()
        try await eventually(player: player) { player.state == .paused }
        let pausedPosition = player.position
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(player.position, pausedPosition, accuracy: 0.1)
        player.seek(to: 3)
        XCTAssertEqual(player.position, 3, accuracy: 0.1)
        player.play()
        await fulfillment(of: [complete], timeout: 8)
        XCTAssertNil(player.lastError)
        XCTAssertEqual(player.position, player.duration, accuracy: 0.1)
    }

    @MainActor
    func testCUEPlaybackUsesSegmentRelativeTimelineAndStopsAtBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokSegmentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("album.wav")
        try wave(duration: 6).write(to: url)
        let player = VLCPlaybackEngine()
        player.volume = 0
        let completed = expectation(description: "CUE segment completed")
        completed.expectedFulfillmentCount = 1
        completed.assertForOverFulfill = true
        player.onCompletion = { completed.fulfill() }
        player.load(url: url, segmentStart: 2, segmentEnd: 3.2)
        try await eventually(player: player) { player.state == .playing || player.position > 0 }
        XCTAssertEqual(player.duration, 1.2, accuracy: 0.05)
        XCTAssertLessThanOrEqual(player.position, 1.2)
        await fulfillment(of: [completed], timeout: 8)
        XCTAssertEqual(player.position, 1.2, accuracy: 0.05)
        XCTAssertNil(player.lastError)
    }

    @MainActor
    func testSeekImmediatelyAfterLoadIsAppliedOnceMediaBecomesSeekable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokResumeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("resume.wav")
        try wave(duration: 8).write(to: url)
        let player = VLCPlaybackEngine()
        player.volume = 0
        player.load(url: url, durationHint: 8)
        player.seek(to: 4)
        try await eventually(player: player) { player.isSeekable && player.position >= 4 }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThanOrEqual(player.position, 4)
        XCTAssertLessThan(player.position, 6)
        player.stop()
    }

    @MainActor
    func testStreamBackedPlaybackCanSeekAndComplete() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokStreamTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stream.wav")
        try wave(duration: 5).write(to: url)
        let stream = try XCTUnwrap(InputStream(url: url))
        let player = VLCPlaybackEngine()
        player.volume = 0
        let completed = expectation(description: "Stream-backed VLC completed")
        player.onCompletion = { completed.fulfill() }
        player.load(stream: stream, durationHint: 5)
        try await eventually(player: player) { player.state == .playing && player.isSeekable }
        player.seek(to: 3)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThanOrEqual(player.position, 3)
        await fulfillment(of: [completed], timeout: 8)
        XCTAssertNil(player.lastError)
    }

    @MainActor
    func testExplicitStopDoesNotAdvanceTheQueue() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "silence.flac", withExtension: nil, subdirectory: "Fixtures"))
        let player = VLCPlaybackEngine()
        player.volume = 0
        var completions = 0
        player.onCompletion = { completions += 1 }
        player.load(url: url)
        try await eventually(player: player) { player.state == .playing }
        player.stop()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(player.state, .stopped)
    }

    @MainActor
    func testTimelineKeepsUpdatingDuringMenuTrackingAndRespectsPauseAndStop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokTrackingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracking.wav")
        try wave(duration: 12).write(to: url)
        let player = VLCPlaybackEngine()
        player.volume = 0
        defer { player.stop() }
        player.load(url: url)
        try await eventually(player: player) { player.state == .playing && player.isSeekable && player.position > 0.2 }

        let initialPosition = player.position
        let playing = runMenuTracking(player: player, duration: 1.2)
        XCTAssertEqual(playing.defaultTicks, 0, "The regression must exclude the default run-loop mode.")
        XCTAssertGreaterThan(playing.commonTicks, 5, "Common-mode sources must remain active during menu tracking.")
        XCTAssertGreaterThan(playing.position, initialPosition + 0.4,
                             "The timeline must advance before leaving the menu-tracking run loop.")

        player.pause()
        try await eventually(player: player) { player.state == .paused }
        let pausedPosition = player.position
        let paused = runMenuTracking(player: player, duration: 0.6)
        XCTAssertEqual(paused.position, pausedPosition, accuracy: 0.1)
        XCTAssertEqual(player.state, .paused)

        player.stop()
        let stopped = runMenuTracking(player: player, duration: 0.6)
        XCTAssertEqual(stopped.position, 0, accuracy: 0.001)
        XCTAssertEqual(player.state, .stopped)
        XCTAssertNil(player.lastError)
    }

    @MainActor
    private func runMenuTracking(player: VLCPlaybackEngine, duration: TimeInterval)
        -> (position: Double, defaultTicks: Int, commonTicks: Int) {
        // Exercise the nested event loop directly without opening a desktop menu.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString))
        var defaultTicks = 0
        var commonTicks = 0
        let defaultTimer = Timer(timeInterval: 0.02, repeats: true) { _ in defaultTicks += 1 }
        let commonTimer = Timer(timeInterval: 0.02, repeats: true) { _ in commonTicks += 1 }
        RunLoop.main.add(defaultTimer, forMode: .default)
        RunLoop.main.add(commonTimer, forMode: .common)
        defer { defaultTimer.invalidate(); commonTimer.invalidate() }
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: deadline)
        }
        // Capture the value before the default loop can deliver any deferred callbacks.
        return (player.position, defaultTicks, commonTicks)
    }

    @MainActor
    private func eventually(player: VLCPlaybackEngine, timeout: TimeInterval = 10,
                            _ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            if player.state == .failed { throw TestFailure.playback(player.lastError ?? "VLC failed") }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw TestFailure.playback("Timed out waiting for VLC; state: \(player.state), position: \(player.position)")
    }

    private func wave(duration: Int) -> Data {
        let sampleRate = 16_000
        let byteCount = duration * sampleRate * 2
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + byteCount)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(byteCount))
        data.append(Data(repeating: 0, count: byteCount))
        return data
    }

    private enum TestFailure: Error { case playback(String) }
}
