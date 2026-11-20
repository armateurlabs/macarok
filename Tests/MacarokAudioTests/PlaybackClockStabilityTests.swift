import Foundation
@testable import MacarokAudio
import XCTest

/// VLC's clock follows the audio output, so a Bluetooth device renegotiating its output latency makes
/// the reported position jump forward and snap back while the audio keeps playing, and a wired device's
/// steady output latency makes the clock lead real time by a constant. The cursor must follow the clock
/// when it moves consistently, hold through oscillating steps, freeze when the clock stalls, and adopt a
/// clock that keeps disagreeing because it really moved.
final class PlaybackClockStabilityTests: XCTestCase {
    private func anchor(_ position: Double, at uptime: TimeInterval, rate: Double = 1) -> PlaybackClockAnchor {
        PlaybackClockAnchor(position: position, uptime: uptime, rate: rate,
                            lastReportedPosition: position, lastReportedUptime: uptime)
    }

    func testForwardBluetoothJumpIsHeldThenResynced() {
        var anchor = anchor(10, at: 100)
        var result = VLCPlaybackEngine.stablePlayingPosition(reported: 12, anchor: anchor, playing: true, now: 100.2)
        XCTAssertEqual(result.position, 10.2, accuracy: 0.001, "A latency-step sample must not move the cursor off the line.")
        anchor = result.anchor
        result = VLCPlaybackEngine.stablePlayingPosition(reported: 10.3, anchor: anchor, playing: true, now: 100.4)
        XCTAssertEqual(result.position, 10.3, accuracy: 0.001, "Once the clock snaps back onto the line, the sample is adopted.")
        XCTAssertEqual(result.anchor.disagreeSince, nil)
    }

    func testBackwardSnapKeepsTheCursorAdvancing() {
        var anchor = anchor(10, at: 100)
        var result = VLCPlaybackEngine.stablePlayingPosition(reported: 10.1, anchor: anchor, playing: true, now: 100.2)
        anchor = result.anchor
        result = VLCPlaybackEngine.stablePlayingPosition(reported: 8, anchor: anchor, playing: true, now: 100.4)
        XCTAssertEqual(result.position, anchor.position + anchor.rate * 0.2, accuracy: 0.001,
                       "A backward step is an artifact; the cursor keeps its line, never rewinding.")
        anchor = result.anchor
        result = VLCPlaybackEngine.stablePlayingPosition(reported: 10.5, anchor: anchor, playing: true, now: 100.6)
        XCTAssertEqual(result.position, 10.5, accuracy: 0.001, "The cursor rejoins the clock once it catches up.")
    }

    func testSteadyClockLeadIsFollowedWithoutJumps() {
        // Wired output: the clock sits ~2 s ahead of the cursor line and advances at real-time rate.
        var anchor = anchor(10, at: 100)
        var result = VLCPlaybackEngine.stablePlayingPosition(reported: 10.2, anchor: anchor, playing: true, now: 100.2)
        XCTAssertEqual(result.position, 10.2, accuracy: 0.001)
        anchor = result.anchor
        // The clock steps ahead and stays there, advancing at real-time rate: held briefly, then adopted.
        result = VLCPlaybackEngine.stablePlayingPosition(reported: 12, anchor: anchor, playing: true, now: 100.4)
        XCTAssertEqual(result.position, anchor.position + anchor.rate * 0.2, accuracy: 0.001)
        anchor = result.anchor
        result = VLCPlaybackEngine.stablePlayingPosition(reported: 15.1, anchor: anchor, playing: true, now: 103.5)
        XCTAssertEqual(result.position, 15.1, accuracy: 0.001, "A sustained lead is real and must be adopted.")
        anchor = result.anchor
        result = VLCPlaybackEngine.stablePlayingPosition(reported: 15.3, anchor: anchor, playing: true, now: 103.7)
        XCTAssertEqual(result.position, 15.3, accuracy: 0.001, "After adoption the line follows the clock, so no sawtooth jumps.")
        XCTAssertEqual(result.anchor.rate, 1, accuracy: 0.01)
    }

    func testSustainedDisagreementIsAdoptedAsARealJump() {
        let anchor = anchor(10, at: 100)
        let held = VLCPlaybackEngine.stablePlayingPosition(reported: 12, anchor: anchor, playing: true, now: 100.2)
        XCTAssertEqual(held.position, 10.2, accuracy: 0.001)
        let adopted = VLCPlaybackEngine.stablePlayingPosition(reported: 14, anchor: held.anchor, playing: true, now: 103.3)
        XCTAssertEqual(adopted.position, 14, accuracy: 0.001, "A clock that stays ahead is a real jump, not latency churn.")
        XCTAssertEqual(adopted.anchor.disagreeSince, nil)
    }

    func testSamplesAgreeingWithinToleranceCorrectDriftWithoutHolding() {
        let anchor = anchor(10, at: 100)
        let leading = VLCPlaybackEngine.stablePlayingPosition(reported: 10.6, anchor: anchor, playing: true, now: 100.2)
        XCTAssertEqual(leading.position, 10.6, accuracy: 0.001, "A sample inside the lead tolerance is the audible truth.")
        let lagging = VLCPlaybackEngine.stablePlayingPosition(reported: 9.8, anchor: anchor, playing: true, now: 100.2)
        XCTAssertEqual(lagging.position, 9.8, accuracy: 0.001, "A sample inside the lag tolerance corrects drift.")
    }

    func testGradualDecoderStallFreezesTheCursor() {
        var anchor = anchor(10, at: 100)
        for step in 1...4 {
            let result = VLCPlaybackEngine.stablePlayingPosition(reported: 10, anchor: anchor, playing: true,
                                                                 now: 100 + Double(step) * 0.2)
            XCTAssertEqual(result.position, 10, accuracy: 0.001, "A freezing clock must freeze the cursor, not run ahead.")
            anchor = result.anchor
        }
    }

    func testHardStallResyncsOntoTheFrozenClock() {
        var anchor = anchor(10, at: 100)
        let stepped = VLCPlaybackEngine.stablePlayingPosition(reported: 9.5, anchor: anchor, playing: true, now: 100.2)
        XCTAssertEqual(stepped.position, 10.2, accuracy: 0.001, "A single backward step is held; it may be latency churn.")
        anchor = stepped.anchor
        let resynced = VLCPlaybackEngine.stablePlayingPosition(reported: 9.5, anchor: anchor, playing: true, now: 103.3)
        XCTAssertEqual(resynced.position, 9.5, accuracy: 0.001, "A clock that stops on its own is the audio stopping; freeze on it.")
        XCTAssertEqual(resynced.anchor.rate, 0, accuracy: 0.001, "The learned rate settles onto the stalled clock.")
    }

    func testNonPlayingStatesRepublishAndReanchor() {
        let anchor = anchor(10, at: 100)
        let buffering = VLCPlaybackEngine.stablePlayingPosition(reported: 10.1, anchor: anchor, playing: false, now: 105)
        XCTAssertEqual(buffering.position, 10.1, accuracy: 0.001, "Buffering must publish the frozen clock, not a running line.")
        XCTAssertEqual(buffering.anchor.position, 10.1, accuracy: 0.001)
        XCTAssertEqual(buffering.anchor.uptime, 105, accuracy: 0.001)
        XCTAssertEqual(buffering.anchor.rate, 1, accuracy: 0.001, "A re-anchor starts at real-time rate.")
    }

    func testPausedStaleSampleCannotRewindTheCursor() {
        let anchor = anchor(10, at: 100)
        let paused = VLCPlaybackEngine.stablePlayingPosition(reported: 0.6, anchor: anchor, playing: false, now: 100.2)
        XCTAssertEqual(paused.position, 10, accuracy: 0.001,
                       "VLCKit's cached pre-seek time must not pull a paused cursor back.")
        XCTAssertEqual(paused.anchor.position, 10, accuracy: 0.001)
    }

    func testFirstSampleWithoutAnAnchorIsAdopted() {
        let result = VLCPlaybackEngine.stablePlayingPosition(reported: 37.5, anchor: nil, playing: true, now: 200)
        XCTAssertEqual(result.position, 37.5, accuracy: 0.001)
        XCTAssertEqual(result.anchor.position, 37.5, accuracy: 0.001)
        XCTAssertEqual(result.anchor.uptime, 200, accuracy: 0.001)
    }
}
