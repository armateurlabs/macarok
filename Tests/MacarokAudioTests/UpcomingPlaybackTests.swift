import Foundation
@testable import MacarokAudio
import XCTest

final class UpcomingPlaybackTests: XCTestCase {
    @MainActor
    func testPreparedSuccessorStartsAndAdvancesWhileMainActorIsBlocked() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let player = VLCPlaybackEngine()
        player.volume = 0
        let token = UUID()
        var handoffs: [UUID] = [], completions = 0
        player.onHandoff = { handoffs.append($0) }
        player.onCompletion = { completions += 1 }
        defer { player.onHandoff = nil; player.onCompletion = nil; player.stop() }
        player.load(url: fixture.url, segmentEnd: 1.8, bufferSeconds: 0.1)
        try await eventually(player) { player.state == .playing && player.position > 0.1 }
        XCTAssertTrue(player.setUpcoming(token: token, url: fixture.url, segmentStart: 3, segmentEnd: 11,
                                        bufferSeconds: 0.1))

        // Deliberately prevent both delegate Tasks and timeline timers from running. A background
        // sort alone cannot establish independence from main-actor queue advancement.
        let output = measureOutputWhileBlockingMainRunLoop(player, token: token, for: 4)

        XCTAssertEqual(player.nativePlaybackToken, token)
        let earlier = try XCTUnwrap(output.earlier, "The successor never reached native audio output while the main run loop was blocked.")
        let later = try XCTUnwrap(output.later, "No later native audio-output sample was available during the block.")
        XCTAssertGreaterThan(later, earlier,
                             "The successor must continue playing audio buffers across samples at least 750 ms apart while MainActor is blocked.")
        XCTAssertTrue(handoffs.isEmpty, "Application publication remains on the main actor.")
        player.synchronizeUpcomingPlayback()
        XCTAssertEqual(handoffs, [token])
        XCTAssertEqual(completions, 0, "A handoff must not also dispatch legacy queue advancement.")
        XCTAssertEqual(player.duration, 8, accuracy: 0.01)
        XCTAssertLessThan(try XCTUnwrap(player.lastHandoffStartedAt), Date().addingTimeInterval(-0.2))
        XCTAssertLessThan(try XCTUnwrap(player.diagnostics.lastTransitionSeconds), 2,
                          "Transition latency must measure native opening, excluding delayed main-actor adoption.")
        player.synchronizeUpcomingPlayback()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(handoffs, [token], "Deferred native events cannot publish the same adoption twice.")
        XCTAssertNil(player.lastError)
    }

    @MainActor
    func testManualPreparedStreamHandoffIsSynchronousAndKeepsSegmentRelativeSeeking() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let player = VLCPlaybackEngine()
        player.volume = 0
        var handoffs: [UUID] = [], completions = 0
        player.onHandoff = { handoffs.append($0) }
        player.onCompletion = { completions += 1 }
        defer { player.onHandoff = nil; player.onCompletion = nil; player.stop() }
        player.load(url: fixture.url)
        try await eventually(player) { player.state == .playing && player.position > 0.1 }
        let cancelled = UUID(), selected = UUID()
        XCTAssertTrue(player.setUpcoming(token: cancelled, url: fixture.url))
        let stream = try XCTUnwrap(InputStream(url: fixture.url))
        XCTAssertTrue(player.setUpcoming(token: selected, stream: stream, segmentStart: 3, segmentEnd: 11,
                                        bufferSeconds: 0.1, supportsSeeking: { true }))
        let originalPosition = player.position
        XCTAssertFalse(player.playUpcoming(token: cancelled))
        XCTAssertEqual(player.position, originalPosition)
        XCTAssertTrue(handoffs.isEmpty)

        XCTAssertTrue(player.playUpcoming(token: selected))

        XCTAssertEqual(handoffs, [selected], "The caller must be able to adopt its prepared transport immediately.")
        XCTAssertEqual(player.duration, 8, accuracy: 0.01)
        player.seek(to: 4)
        try await eventually(player) { player.isSeekable && player.position >= 4 }
        player.pause()
        try await eventually(player) { player.state == .paused }
        XCTAssertGreaterThanOrEqual(player.position, 4)
        XCTAssertLessThan(player.position, 6)
        XCTAssertEqual(completions, 0)
        XCTAssertNil(player.lastError)

        // Repeat Track reuses the queue entry UUID but must create a fresh playback occurrence.
        XCTAssertTrue(player.setUpcoming(token: selected, url: fixture.url, segmentStart: 3, segmentEnd: 11))
        XCTAssertTrue(player.playUpcoming(token: selected))
        XCTAssertEqual(handoffs, [selected, selected])
        XCTAssertEqual(player.position, 0, accuracy: 0.01)
    }

    @MainActor
    func testStopInvalidatesAlreadyStartedNativeHandoffWithoutPublishingOrResurrectingIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let player = VLCPlaybackEngine()
        player.volume = 0
        let token = UUID()
        var handoffs = 0, completions = 0
        player.onHandoff = { _ in handoffs += 1 }
        player.onCompletion = { completions += 1 }
        defer { player.onHandoff = nil; player.onCompletion = nil; player.stop() }
        player.load(url: fixture.url, segmentEnd: 1.5, bufferSeconds: 0.1)
        try await eventually(player) { player.state == .playing && player.position > 0.1 }
        XCTAssertTrue(player.setUpcoming(token: token, url: fixture.url, bufferSeconds: 0.1))
        blockMainRunLoop(for: 3)
        XCTAssertEqual(player.nativePlaybackToken, token)

        player.stop()
        player.synchronizeUpcomingPlayback()
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertNil(player.nativePlaybackToken)
        XCTAssertEqual(handoffs, 0, "Explicit Stop cancels the native successor without reviving queue state.")
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(player.state, .stopped)
        XCTAssertEqual(player.position, 0)
    }

    @MainActor
    func testCancelledPreparationAndLiveEOFNeverPromoteTheNextEntry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let player = VLCPlaybackEngine()
        player.volume = 0
        var handoffs = 0, completions = 0
        player.onHandoff = { _ in handoffs += 1 }
        player.onCompletion = { completions += 1 }
        defer { player.onHandoff = nil; player.onCompletion = nil; player.stop() }
        player.load(url: fixture.url, segmentEnd: 1.5, bufferSeconds: 0.1)
        try await eventually(player) { player.state == .playing }
        let cancelled = UUID()
        XCTAssertTrue(player.setUpcoming(token: cancelled, url: fixture.url))
        player.cancelUpcoming()
        XCTAssertFalse(player.playUpcoming(token: cancelled))
        try await eventually(player) { completions == 1 }
        XCTAssertEqual(handoffs, 0)

        // A finite fixture stands in for a radio stream that unexpectedly closes its connection.
        player.load(url: fixture.url, segmentEnd: 1.5, bufferSeconds: 0.1, live: true)
        try await eventually(player) { player.state == .playing }
        XCTAssertTrue(player.setUpcoming(token: UUID(), url: fixture.url))
        try await eventually(player) { completions == 2 }
        XCTAssertEqual(handoffs, 0, "Radio EOF must remain available for the application's Reconnect flow.")
        XCTAssertEqual(player.state, .stopped)
    }

    @MainActor
    func testStallFailureDoesNotCompleteOrStartPreparedMedia() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let player = VLCPlaybackEngine()
        player.volume = 0
        var handoffs = 0, completions = 0, failures: [String] = []
        player.onHandoff = { _ in handoffs += 1 }
        player.onCompletion = { completions += 1 }
        player.onError = { failures.append($0) }
        defer { player.onHandoff = nil; player.onCompletion = nil; player.onError = nil; player.stop() }
        player.load(url: fixture.url)
        try await eventually(player) { player.state == .playing && player.position > 0.1 }
        XCTAssertNotNil(player.healthSnapshot.playedAudioBuffers)
        XCTAssertTrue(player.setUpcoming(token: UUID(), url: fixture.url))

        player.failStalledPlayback("Audio playback stopped advancing. Reconnect to try again.")
        player.failStalledPlayback("Duplicate watchdog sample")
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(player.state, .failed)
        XCTAssertEqual(failures, ["Audio playback stopped advancing. Reconnect to try again."])
        XCTAssertEqual(handoffs, 0)
        XCTAssertEqual(completions, 0)
    }

    @MainActor
    private func eventually(_ player: VLCPlaybackEngine, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if condition() { return }
            if player.state == .failed { throw Failure.playback(player.lastError ?? "VLC failed") }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure.playback("Timed out; state: \(player.state), position: \(player.position)")
    }

    private func blockMainRunLoop(for seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func measureOutputWhileBlockingMainRunLoop(_ player: VLCPlaybackEngine, token: UUID, for seconds: TimeInterval)
        -> (earlier: UInt64?, later: UInt64?) {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var firstOutputTime: TimeInterval?, baselineTime: TimeInterval?
        var earlier: UInt64?, later: UInt64?
        while ProcessInfo.processInfo.systemUptime < deadline {
            let now = ProcessInfo.processInfo.systemUptime
            if player.nativePlaybackToken == token, let counter = player.nativePlayedAudioBuffers {
                if firstOutputTime == nil { firstOutputTime = now }
                // VLCMediaPlayer.time copies a cached clock in the pinned framework. The public
                // media statistics call libvlc_media_get_stats directly, and playedAudioBuffers
                // counts output rather than decoder/read-ahead work. Sample after startup, then
                // again 750 ms later without pumping AppKit, timers, or main-actor Tasks.
                if let firstOutputTime, now - firstOutputTime >= 0.5 {
                    if baselineTime == nil { baselineTime = now; earlier = counter }
                    else if let baselineTime, now - baselineTime >= 0.75 { later = counter }
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return (earlier, later)
    }

    private enum Failure: Error { case playback(String) }

    private struct Fixture {
        let directory: URL
        let url: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokUpcoming-\(UUID())")
            url = directory.appendingPathComponent("album.wav")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sampleRate = 16_000, byteCount = 12 * sampleRate * 2
            var data = Data("RIFF".utf8)
            func append<T: FixedWidthInteger>(_ value: T) {
                var value = value.littleEndian
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            }
            append(UInt32(36 + byteCount)); data.append(Data("WAVEfmt ".utf8))
            append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate))
            append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
            data.append(Data("data".utf8)); append(UInt32(byteCount))
            data.append(Data(repeating: 0, count: byteCount))
            try data.write(to: url)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
