import AppKit
import XCTest
@testable import MacarokApp

final class PlaybackTimelineSmoothingTests: XCTestCase {
    func testReceivedPositionsMoveSmoothlyWithoutExtrapolatingPastTheMeasurement() {
        let generation = UUID()
        var clock = PlaybackTimelineSmoothing()
        XCTAssertEqual(clock.update(to: 10, at: 0, playing: true, generation: generation, seekRevision: 0), 10)
        XCTAssertEqual(clock.update(to: 10.2, at: 0.2, playing: true, generation: generation, seekRevision: 0), 10)
        XCTAssertEqual(clock.value(at: 0.25), 10.05, accuracy: 0.0001)
        XCTAssertEqual(clock.value(at: 0.3), 10.1, accuracy: 0.0001)
        XCTAssertEqual(clock.value(at: 0.4), 10.2, accuracy: 0.0001)
        XCTAssertEqual(clock.value(at: 600), 10.2, "A stalled decoder cannot acquire invented playback time.")
        XCTAssertFalse(clock.isAnimating(at: 600))
    }

    func testDuplicateUpdatesDoNotRestartOrExtendTheLastTransition() {
        let generation = UUID()
        var clock = PlaybackTimelineSmoothing()
        _ = clock.update(to: 10, at: 0, playing: true, generation: generation, seekRevision: 0)
        _ = clock.update(to: 10.2, at: 0.2, playing: true, generation: generation, seekRevision: 0)
        _ = clock.update(to: 10.2, at: 0.3, playing: true, generation: generation, seekRevision: 0)
        XCTAssertEqual(clock.value(at: 0.35), 10.15, accuracy: 0.0001)
        XCTAssertEqual(clock.value(at: 0.4), 10.2, accuracy: 0.0001)
        XCTAssertFalse(clock.isAnimating(at: 0.41))
    }

    func testPauseBufferingOrDraggingSnapToConfirmedTimeAndCancelInterpolation() {
        let generation = UUID()
        var clock = PlaybackTimelineSmoothing()
        _ = clock.update(to: 10, at: 0, playing: true, generation: generation, seekRevision: 0)
        _ = clock.update(to: 10.2, at: 0.2, playing: true, generation: generation, seekRevision: 0)
        XCTAssertLessThan(clock.value(at: 0.25), 10.2)

        XCTAssertEqual(clock.update(to: 10.2, at: 0.25, playing: false, generation: generation, seekRevision: 0), 10.2)

        XCTAssertFalse(clock.isAnimating(at: 0.25))
        XCTAssertEqual(clock.value(at: 60), 10.2)
    }

    func testEverySeekAndOccurrenceChangeSnapEvenForSmallForwardMovements() {
        let generation = UUID()
        var clock = PlaybackTimelineSmoothing()
        _ = clock.update(to: 10, at: 0, playing: true, generation: generation, seekRevision: 0)
        _ = clock.update(to: 10.2, at: 0.2, playing: true, generation: generation, seekRevision: 0)

        XCTAssertEqual(clock.update(to: 10.3, at: 0.25, playing: true, generation: generation, seekRevision: 1), 10.3)
        XCTAssertFalse(clock.isAnimating(at: 0.25))
        XCTAssertEqual(clock.update(to: 10.4, at: 0.3, playing: true, generation: UUID(), seekRevision: 1), 10.4)
        XCTAssertFalse(clock.isAnimating(at: 0.3))
    }

    func testBackwardJumpsLargeJumpsAndDelayedSamplesDoNotAnimateCatchUp() {
        let generation = UUID()
        var clock = PlaybackTimelineSmoothing()
        _ = clock.update(to: 10, at: 0, playing: true, generation: generation, seekRevision: 0)
        XCTAssertEqual(clock.update(to: 9, at: 0.2, playing: true, generation: generation, seekRevision: 0), 9)
        XCTAssertEqual(clock.update(to: 14, at: 0.4, playing: true, generation: generation, seekRevision: 0), 14)
        XCTAssertEqual(clock.update(to: 14.5, at: 2, playing: true, generation: generation, seekRevision: 0), 14.5)
        XCTAssertFalse(clock.isAnimating(at: 2))
    }

    @MainActor
    func testNativeValueAndAccessibilityStayMeasuredWhileOnlyTheCellPaintingInterpolates() throws {
        _ = NSApplication.shared
        let slider = BufferedTimelineSlider.makeSlider()
        slider.minValue = 0; slider.maxValue = 100
        let generation = UUID()
        defer { slider.stopPresentationUpdates() }
        slider.applyPlaybackPosition(10, playing: true, generation: generation, seekRevision: 0, at: 0)
        slider.applyPlaybackPosition(10.2, playing: true, generation: generation, seekRevision: 0, at: 0.2)

        slider.advancePresentation(to: 0.3)

        XCTAssertEqual(slider.doubleValue, 10.2)
        // NSSlider is an accessibility container; its native NSSliderCell is the AXSlider element.
        let accessibleSlider = try XCTUnwrap(slider.accessibilityChildren()?.compactMap { $0 as? NSSliderCell }.first)
        XCTAssertEqual(accessibleSlider.accessibilityRole(), .slider)
        let accessibleValue = try XCTUnwrap(accessibleSlider.accessibilityValue() as? NSNumber)
        XCTAssertEqual(accessibleValue.doubleValue, 10.2, accuracy: 0.0001)
        XCTAssertEqual(slider.renderedPosition, 10.1, accuracy: 0.0001)
        // The native action executes synchronously, before SwiftUI can echo its new binding.
        slider.doubleValue = 42
        slider.synchronizeInputPresentation()
        XCTAssertEqual(slider.renderedPosition, 42)
        slider.advancePresentation(to: 1)
        XCTAssertEqual(slider.renderedPosition, 42)
    }
}
