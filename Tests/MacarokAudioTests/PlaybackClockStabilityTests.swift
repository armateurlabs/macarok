@testable import MacarokAudio
import XCTest

/// The cursor has two states: it runs at exactly real-time rate while audio plays, or stands still.
/// It starts and stops where it stands; VLC's clock never bends it, and a lasting disagreement is a
/// synchronization error.
final class PlaybackClockStabilityTests: XCTestCase {
    func testPauseAndResumeNeverMoveTheCursor() {
        var cursor = PlaybackCursor()
        cursor.stop(at: 10, now: 100)
        cursor.run(at: 100)
        cursor.stop(at: cursor.clock.position(at: 101.5), now: 101.5)
        XCTAssertEqual(cursor.clock, PlaybackClock(position: 11.5, uptime: 101.5, isRunning: false))
        cursor.run(at: 103)
        XCTAssertEqual(cursor.clock, PlaybackClock(position: 11.5, uptime: 103, isRunning: true),
                       "Resuming starts from where the cursor stopped, whatever VLC's lagging clock reports.")
        cursor.run(at: 104)
        XCTAssertEqual(cursor.clock.uptime, 103, "A running cursor is never restarted.")
    }

    func testRunningCursorIgnoresBluetoothLatencySteps() {
        var cursor = PlaybackCursor()
        cursor.stop(at: 10, now: 100)
        cursor.run(at: 100)
        let running = cursor.clock
        // A latency renegotiation makes VLC's clock jump forward, then snap back.
        for (sample, now) in [(12.4, 100.6), (12.6, 100.8), (10.6, 101.0), (8.9, 101.2), (11.1, 102)] {
            XCTAssertNil(cursor.check(sample, at: now))
            XCTAssertEqual(cursor.clock, running, "A running cursor keeps one real-time line whatever VLC reports.")
        }
    }

    func testLastingDriftIsCorrectedOnceAsASynchronizationError() {
        var cursor = PlaybackCursor()
        cursor.run(at: 0)
        XCTAssertNil(cursor.check(5, at: 1))
        XCTAssertNil(cursor.check(6.9, at: 2.9))
        XCTAssertEqual(try XCTUnwrap(cursor.check(7.2, at: 3.2)), 4, accuracy: 1e-9)
        XCTAssertEqual(cursor.clock, PlaybackClock(position: 7.2, uptime: 3.2, isRunning: true))
        XCTAssertNil(cursor.check(7.4, at: 3.4), "Back in sync after one placement.")
        cursor.stop(at: 8, now: 4)
        XCTAssertNil(cursor.check(0.6, at: 5), "A stopped cursor ignores VLC's clock.")
        XCTAssertEqual(cursor.clock.position(at: 200), 8)
    }
}
