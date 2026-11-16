import Foundation
import XCTest
@testable import MacarokCore

final class PlaybackWatchdogTests: XCTestCase {
    private let occurrence = UUID()
    private func sample(_ time: Double, position: Double? = 10, phase: PlaybackWatchdog.Phase = .playing,
                        live: Bool = false, output: UInt64? = nil, transport: UInt64? = nil,
                        seeking: Bool = false, suspended: Bool = false, expectedBuffer: Double? = nil,
                        id: UUID? = nil) -> PlaybackWatchdog.Sample {
        .init(occurrenceID: id ?? occurrence, monotonicTime: time, phase: phase, position: position,
              isLive: live, isSeeking: seeking, isSuspended: suspended, audioOutputCounter: output,
              transportProgressCounter: transport, expectedBufferSeconds: expectedBuffer)
    }
    private func feed(_ watchdog: inout PlaybackWatchdog, times: ClosedRange<Int>,
                      position: Double? = 10, phase: PlaybackWatchdog.Phase = .playing) -> [PlaybackWatchdog.Incident] {
        times.compactMap { watchdog.sample(sample(Double($0), position: position, phase: phase)) }
    }

    func testFrozenPlaybackReportsOnceAndNewOccurrenceCanReportAgain() {
        var watchdog = PlaybackWatchdog()
        let incidents = feed(&watchdog, times: 0...30)
        XCTAssertEqual(incidents.count, 1)
        XCTAssertEqual(incidents.first?.reason, .progressStalled)
        XCTAssertEqual(incidents.first?.secondsWithoutProgress, 12)
        XCTAssertEqual(incidents.first?.occurrenceID, occurrence)
        let next = UUID()
        for time in 31...42 { XCTAssertNil(watchdog.sample(sample(Double(time), id: next))) }
        XCTAssertEqual(watchdog.sample(sample(43, id: next))?.occurrenceID, next)
    }

    func testActualProgressAndAccumulatedSubsecondPositionAdvancePreventFalseStalls() {
        var watchdog = PlaybackWatchdog()
        for time in 0...100 {
            XCTAssertNil(watchdog.sample(sample(Double(time), position: Double(time) * 0.1)))
        }
        var outputWatchdog = PlaybackWatchdog()
        for time in 0...100 {
            XCTAssertNil(outputWatchdog.sample(sample(Double(time), position: 0, output: UInt64(time))))
        }
    }

    func testIncomingBytesCannotConcealFrozenDecoder() {
        var watchdog = PlaybackWatchdog()
        var incident: PlaybackWatchdog.Incident?
        for time in 0...12 { incident = watchdog.sample(sample(Double(time), output: 20, transport: UInt64(time * 1024))) ?? incident }
        XCTAssertEqual(incident?.reason, .progressStalled)
        XCTAssertEqual(incident?.transportIsAdvancing, true)
    }

    func testOpeningAndBufferingHaveGenerousIndependentThresholds() {
        var opening = PlaybackWatchdog()
        XCTAssertTrue(feed(&opening, times: 0...44, position: nil, phase: .opening).isEmpty)
        XCTAssertEqual(opening.sample(sample(45, position: nil, phase: .opening))?.reason, .openingTimedOut)
        var buffering = PlaybackWatchdog()
        XCTAssertTrue(feed(&buffering, times: 0...29, position: nil, phase: .buffering).isEmpty)
        XCTAssertEqual(buffering.sample(sample(30, position: nil, phase: .buffering))?.reason, .bufferingTimedOut)
    }

    func testFirstPlayingObservationStartsFreshDeadlineAfterLongOpening() {
        var watchdog = PlaybackWatchdog()
        XCTAssertTrue(feed(&watchdog, times: 0...40, phase: .opening).isEmpty)
        XCTAssertTrue(feed(&watchdog, times: 41...52).isEmpty)
        XCTAssertEqual(watchdog.sample(sample(53))?.reason, .progressStalled)
    }

    func testRepeatedBufferingPlayingFlapsDoNotResetProgressDeadline() {
        var watchdog = PlaybackWatchdog()
        XCTAssertNil(watchdog.sample(sample(0)))
        for time in 1...11 {
            XCTAssertNil(watchdog.sample(sample(Double(time), phase: time.isMultiple(of: 2) ? .playing : .buffering)))
        }
        XCTAssertEqual(watchdog.sample(sample(12))?.reason, .progressStalled)
    }

    func testConfiguredLargePrebufferExtendsStartupWaitWithoutDisablingDetection() {
        var watchdog = PlaybackWatchdog()
        for time in 0...99 {
            XCTAssertNil(watchdog.sample(sample(Double(time), phase: .buffering, expectedBuffer: 90)))
        }
        XCTAssertEqual(watchdog.sample(sample(100, phase: .buffering, expectedBuffer: 90))?.reason, .bufferingTimedOut)
    }

    func testPausePreparationAndSuspensionExcludeWaitingTime() {
        for inactive in [PlaybackWatchdog.Phase.paused, .preparing, .stopped, .failed] {
            var watchdog = PlaybackWatchdog()
            XCTAssertTrue(feed(&watchdog, times: 0...10).isEmpty)
            XCTAssertTrue(feed(&watchdog, times: 11...100, phase: inactive).isEmpty)
            XCTAssertTrue(feed(&watchdog, times: 101...112).isEmpty)
            XCTAssertNotNil(watchdog.sample(sample(113)))
        }
        var suspended = PlaybackWatchdog()
        for time in 0...100 { XCTAssertNil(suspended.sample(sample(Double(time), suspended: true))) }
        XCTAssertTrue(feed(&suspended, times: 101...111).isEmpty)
        XCTAssertNotNil(suspended.sample(sample(112)))
    }

    func testClockGapRegressionAndInvalidTimeStartNewObservationWindow() {
        var watchdog = PlaybackWatchdog()
        XCTAssertTrue(feed(&watchdog, times: 0...10).isEmpty)
        XCTAssertNil(watchdog.sample(sample(100)))
        XCTAssertTrue(feed(&watchdog, times: 101...111).isEmpty)
        XCTAssertNil(watchdog.sample(sample(1)))
        XCTAssertTrue(feed(&watchdog, times: 2...12).isEmpty)
        XCTAssertNil(watchdog.sample(sample(.nan)))
        XCTAssertTrue(feed(&watchdog, times: 13...24).isEmpty)
        XCTAssertNotNil(watchdog.sample(sample(25)))
    }

    func testExplicitSeekAndSeekFlagGiveSettlingGraceWithoutSeekingAutomatically() {
        var watchdog = PlaybackWatchdog()
        XCTAssertTrue(feed(&watchdog, times: 0...10).isEmpty)
        watchdog.markSeek(occurrenceID: occurrence, monotonicTime: 10)
        for time in 11...30 { XCTAssertNil(watchdog.sample(sample(Double(time), position: 50))) }
        XCTAssertNotNil(watchdog.sample(sample(31, position: 50)))
        var flagged = PlaybackWatchdog()
        for time in 0...50 { XCTAssertNil(flagged.sample(sample(Double(time), seeking: true))) }
        for time in 51...70 { XCTAssertNil(flagged.sample(sample(Double(time)))) }
        XCTAssertNotNil(flagged.sample(sample(71)))
    }

    func testBackwardDiscontinuityGetsSeekGraceWhenTransientFlagWasMissed() {
        var watchdog = PlaybackWatchdog()
        XCTAssertTrue(feed(&watchdog, times: 0...10, position: 60).isEmpty)
        for time in 11...31 { XCTAssertNil(watchdog.sample(sample(Double(time), position: 10))) }
        XCTAssertNotNil(watchdog.sample(sample(32, position: 10)))
    }

    func testLiveAudioBuffersAreProgressWithoutTimelineAndMissingClockIsNotSilence() {
        var live = PlaybackWatchdog()
        for time in 0...100 {
            XCTAssertNil(live.sample(sample(Double(time), position: nil, live: true, output: UInt64(time))))
        }
        var unknown = PlaybackWatchdog()
        for time in 0...100 { XCTAssertNil(unknown.sample(sample(Double(time), position: nil, live: true))) }
        var frozen = PlaybackWatchdog()
        for time in 0...29 { XCTAssertNil(frozen.sample(sample(Double(time), position: nil, live: true, output: 10))) }
        let incident = frozen.sample(sample(30, position: nil, live: true, output: 10))
        XCTAssertEqual(incident?.reason, .progressStalled)
        XCTAssertEqual(incident?.isLive, true)
    }

    func testPauseAfterIncidentDoesNotCauseRepeatedRecoveryWithinSameOccurrence() {
        var watchdog = PlaybackWatchdog()
        XCTAssertEqual(feed(&watchdog, times: 0...20).count, 1)
        XCTAssertTrue(feed(&watchdog, times: 21...25, phase: .paused).isEmpty)
        XCTAssertTrue(feed(&watchdog, times: 26...100).isEmpty)
        XCTAssertNil(watchdog.sample(.init(occurrenceID: nil, monotonicTime: 101, phase: .stopped, position: nil)))
        XCTAssertEqual(feed(&watchdog, times: 102...114).count, 1)
    }

    func testInvalidConfigurationAndPositionValuesAreSanitized() {
        let config = PlaybackWatchdog.Configuration(playingTimeout: .nan, liveTimeout: -.infinity,
            openingTimeout: -1, bufferingTimeout: 0, seekGrace: .infinity, maximumSampleGap: 0, minimumPositionAdvance: -.infinity)
        XCTAssertEqual(config.playingTimeout, 12)
        XCTAssertEqual(config.liveTimeout, 30)
        XCTAssertEqual(config.openingTimeout, 45)
        XCTAssertEqual(config.bufferingTimeout, 30)
        XCTAssertEqual(config.seekGrace, 10)
        XCTAssertEqual(config.maximumSampleGap, 5)
        XCTAssertEqual(config.minimumPositionAdvance, 0.25)
        XCTAssertNil(sample(0, position: .nan, expectedBuffer: .infinity).position)
        XCTAssertNil(sample(0, position: -1, expectedBuffer: -1).expectedBufferSeconds)
    }
}
