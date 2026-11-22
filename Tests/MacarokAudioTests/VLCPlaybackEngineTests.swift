import AppKit
import Combine
import Foundation
@testable import MacarokAudio
import XCTest

final class VLCPlaybackEngineTests: XCTestCase {
    @MainActor
    func testClockPublishesOnlyToTimelineObserversAndIgnoresDuplicateStop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokClockIsolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clock.wav")
        try wave(duration: 8).write(to: url)
        let player = VLCPlaybackEngine()
        player.volume = 0
        defer { player.stop() }
        var engineChanges = 0, timelineChanges = 0
        let engineObservation = player.objectWillChange.sink { engineChanges += 1 }
        let timelineObservation = player.timeline.objectWillChange.sink { timelineChanges += 1 }
        defer { engineObservation.cancel(); timelineObservation.cancel() }
        player.load(url: url)
        try await eventually(player: player) { player.state == .playing && player.position > 0.2 && player.isSeekable }
        let initialPosition = player.position, initialEngineChanges = engineChanges, initialTimelineChanges = timelineChanges

        try await Task.sleep(for: .milliseconds(750))

        XCTAssertGreaterThan(player.position, initialPosition + 0.3)
        XCTAssertGreaterThan(timelineChanges, initialTimelineChanges)
        XCTAssertEqual(engineChanges, initialEngineChanges,
                       "Queue and radio state observers must not redraw for clock, duration, or seekability samples.")
        player.stop()
        let stoppedEngineChanges = engineChanges, stoppedTimelineChanges = timelineChanges
        player.stop()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(engineChanges, stoppedEngineChanges)
        XCTAssertEqual(timelineChanges, stoppedTimelineChanges,
                       "Repeated stop and cached VLC callbacks must not republish unchanged timeline values.")
    }

    @MainActor
    func testMediaReplacementsReuseTheLibraryAndRejectOldCompletionCallbacks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokReplacementTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replacement.wav")
        // Keep a substantial playback window after file caching; a tiny codec fixture can finish
        // between two legitimate 5 Hz clock samples and cannot prove stale-callback isolation.
        try wave(duration: 8).write(to: url)
        let player = VLCPlaybackEngine()
        player.volume = 0
        var completions = 0
        player.onCompletion = { completions += 1 }
        defer { player.onCompletion = nil; player.stop() }
        player.load(url: url)
        try await eventually(player: player) { player.state == .playing }
        let originalLibrary = try XCTUnwrap(player.libraryIdentity)
        for _ in 0..<6 {
            player.load(url: url, autoplay: false)
            XCTAssertEqual(player.libraryIdentity, originalLibrary)
        }
        player.load(url: url)
        try await eventually(player: player) { player.state == .playing && player.position > 0.1 }
        XCTAssertEqual(player.libraryIdentity, originalLibrary)
        XCTAssertEqual(completions, 0, "Cancelled media must never complete the newly installed queue entry.")
        XCTAssertEqual(player.diagnostics.installationCount, 8)
        XCTAssertGreaterThanOrEqual(player.diagnostics.lastInstallationSeconds, 0)
        XCTAssertNotNil(player.diagnostics.lastTransitionSeconds)
        XCTAssertNil(player.lastError)
    }

    @MainActor
    func testReplacedNativePlayerIsReleasedOffTheMainThread() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokTeardownTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("teardown.wav")
        try wave(duration: 4).write(to: url)
        let player = VLCPlaybackEngine()
        player.volume = 0
        defer { player.stop() }
        autoreleasepool { player.load(url: url) }
        try await eventually(player: player) { player.state == .playing }
        let released = expectation(description: "replaced player released")
        // Hold no strong reference here: only the replaced player owns the probe.
        let replacedID: ObjectIdentifier = try autoreleasepool {
            let replaced = try XCTUnwrap(player.nativePlayerObject)
            let probe = ReleaseProbe { isMain in
                XCTAssertFalse(isMain, "libVLC teardown joins network threads and must not block the main thread.")
                released.fulfill()
            }
            objc_setAssociatedObject(replaced, &ReleaseProbe.key, probe, .OBJC_ASSOCIATION_RETAIN)
            return ObjectIdentifier(replaced)
        }
        autoreleasepool { player.load(url: url) }
        XCTAssertNotEqual(player.nativePlayerObject.map(ObjectIdentifier.init), replacedID)
        await fulfillment(of: [released], timeout: NativePlayerReaper.delay + 10)
    }

    @MainActor
    func testAutomaticTransitionsRecordBoundedGapsWhileBackgroundSortingRuns() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "silence.flac", withExtension: nil, subdirectory: "Fixtures"))
        let player = VLCPlaybackEngine()
        player.volume = 0
        var completed = 0
        var transitionStarted: TimeInterval?
        var measuredGaps: [TimeInterval] = []
        let finished = expectation(description: "Three tracks completed under background load")
        let observation = player.$state.sink { state in
            if state == .playing, let started = transitionStarted {
                measuredGaps.append(ProcessInfo.processInfo.systemUptime - started)
                transitionStarted = nil
            }
        }
        defer { observation.cancel(); player.onCompletion = nil; player.stop() }
        player.onCompletion = {
            completed += 1
            if completed < 3 {
                transitionStarted = ProcessInfo.processInfo.systemUptime
                player.load(url: url)
            } else { finished.fulfill() }
        }
        let backgroundWork = Task.detached(priority: .utility) {
            let titles = (0..<2_000).map { "Synthetic album \(2_000 - $0)" }
            let deadline = ProcessInfo.processInfo.systemUptime + 2.8
            repeat { _ = titles.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
            while ProcessInfo.processInfo.systemUptime < deadline
        }
        player.load(url: url)
        await fulfillment(of: [finished], timeout: 15)
        await backgroundWork.value
        XCTAssertEqual(completed, 3)
        XCTAssertEqual(measuredGaps.count, 2)
        XCTAssertLessThan(measuredGaps.max() ?? .infinity, 2,
                          "Main-actor transition dispatch plus VLC opening must remain bounded during background sorting.")
        XCTAssertEqual(player.diagnostics.installationCount, 3)
        XCTAssertNil(player.lastError)
    }

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
        let seekRevision = player.timeline.seekRevision
        player.seek(to: 4)
        XCTAssertEqual(player.timeline.seekRevision, seekRevision + 1,
                       "Rendering must be able to cancel interpolation even before a pending seek is acknowledged.")
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
        XCTAssertTrue(player.timeline.clock.isRunning, "Playing audio runs the cursor.")

        player.pause()
        try await eventually(player: player) { player.state == .paused }
        XCTAssertFalse(player.timeline.clock.isRunning, "Anything but playing stops the cursor.")
        let pausedPosition = player.position
        let paused = runMenuTracking(player: player, duration: 0.6)
        XCTAssertEqual(paused.position, pausedPosition, accuracy: 0.1)
        XCTAssertEqual(player.state, .paused)

        let pausedClock = player.timeline.clock
        let resumedAt = ProcessInfo.processInfo.systemUptime
        player.play()
        try await eventually(player: player) { player.state == .playing }
        let resumed = player.timeline.clock
        XCTAssertTrue(resumed.isRunning)
        XCTAssertEqual(resumed.position, pausedClock.position, "Resuming starts the cursor where it stopped, without a jump.")
        XCTAssertLessThan(resumed.uptime - resumedAt, 0.3, "The cursor starts with the playing event, not with VLC's lagging clock.")

        player.stop()
        let stopped = runMenuTracking(player: player, duration: 0.6)
        XCTAssertEqual(stopped.position, 0, accuracy: 0.001)
        XCTAssertEqual(player.timeline.clock, PlaybackClock(position: 0, uptime: player.timeline.clock.uptime, isRunning: false))
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

private final class ReleaseProbe: NSObject {
    nonisolated(unsafe) static var key: UInt8 = 0
    private let released: (Bool) -> Void
    init(_ released: @escaping (Bool) -> Void) { self.released = released }
    deinit { released(Thread.isMainThread) }
}
