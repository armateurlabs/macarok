import AppKit
import MacarokAudio
import SwiftUI
import XCTest
@testable import MacarokApp

@MainActor
final class PlaybackTimelineTrackingTests: XCTestCase {
    func testHostedNativeMouseEventsReachExactForwardAndBackwardReleasePositions() throws {
        for playing in [true, false] {
            for (start, destination) in [(9.104, 45.0), (55.026, 22.5), (58.394, 22.5)] {
                let fixture = Fixture(playing: playing, position: start)
                let window = host(fixture.slider, width: 907.5)
                defer { fixture.stop(); window.contentView = nil; window.close() }
                let bar = fixture.slider.playbackTrackRect
                func event(_ type: NSEvent.EventType, value: Double, number: Int) throws -> NSEvent {
                    let point = fixture.slider.convert(NSPoint(x: bar.minX + bar.width * value / 90, y: bar.midY), to: nil)
                    return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: TimeInterval(number), windowNumber: window.windowNumber, context: nil,
                        eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
                }
                if playing {
                    fixture.onDraftChanged = {
                        fixture.measured += 0.2
                        fixture.publish(queuedValue: fixture.measured)
                    }
                }
                // Queue real AppKit tracking events only in this process's offscreen window.
                // A distinct final release coordinate proves mouse-up is mapped as well as drag.
                window.postEvent(try event(.leftMouseDragged, value: (start + destination) / 2, number: 2), atStart: false)
                window.postEvent(try event(.leftMouseUp, value: destination, number: 3), atStart: false)

                fixture.slider.mouseDown(with: try event(.leftMouseDown, value: start, number: 1))

                XCTAssertEqual(fixture.seeks.count, 1)
                XCTAssertEqual(try XCTUnwrap(fixture.seeks.first), destination, accuracy: 0.0001)
                XCTAssertEqual(fixture.slider.doubleValue, destination, accuracy: 0.0001)
                XCTAssertEqual(try accessibleValue(fixture.slider), destination, accuracy: 0.0001)
                fixture.onDraftChanged = nil
            }
        }
    }

    func testHostedVisibleThumbAndNativeHitRectAgreeAcrossFractionsWidthsAndAppearances() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for width in [CGFloat(420), 907.5] {
                let fixture = Fixture(playing: false, position: 0)
                let window = host(fixture.slider, width: width)
                window.appearance = NSAppearance(named: appearance)
                defer { fixture.stop(); window.contentView = nil; window.close() }
                let cell = try XCTUnwrap(fixture.slider.cell as? NSSliderCell)
                for fraction in [0.05, 0.25, 0.5, 0.65, 0.9] {
                    fixture.measured = fraction * 90
                    fixture.publish()
                    let native = cell.knobRect(flipped: fixture.slider.isFlipped)
                    let visible = fixture.slider.playbackThumbRect
                    XCTAssertEqual(visible.midX, native.midX, accuracy: 0.5)
                    XCTAssertEqual(visible.width, 16)
                    XCTAssertEqual(visible.height, 16)
                    XCTAssertTrue(fixture.slider.bounds.contains(visible),
                                  "A drawn thumb must remain inside the expanded native input surface.")
                }
            }
        }
    }

    func testPlayingAndPausedDragsIgnoreQueuedClockAndDraftWritesAndCommitFinalNativeValueOnce() throws {
        for playing in [true, false] {
            let fixture = Fixture(playing: playing, position: playing ? 69.803 : 4.162)
            defer { fixture.stop() }
            XCTAssertTrue(fixture.slider.beginTrackingGesture())
            fixture.sendNativeAction(50)

            fixture.measured += playing ? 0.2 : 0
            fixture.duration = 91
            fixture.publish(queuedValue: fixture.measured)

            XCTAssertEqual(fixture.slider.doubleValue, 50, "Playback publication cannot reset AppKit's in-progress tracking value.")
            XCTAssertEqual(fixture.slider.maxValue, 90, "A late decoded duration cannot remap the native drag mid-gesture.")
            XCTAssertEqual(fixture.slider.renderedPosition, 50)
            fixture.sendNativeAction(22.5)
            fixture.measured += playing ? 0.2 : 0
            fixture.publish(queuedValue: 50) // A queued SwiftUI echo from the preceding mouse event.
            XCTAssertEqual(fixture.slider.doubleValue, 22.5)
            XCTAssertEqual(fixture.slider.renderedPosition, 22.5)
            XCTAssertTrue(fixture.seeks.isEmpty, "Continuous native actions update the draft without seeking the engine.")

            fixture.slider.finishTrackingGesture()
            fixture.slider.finishTrackingGesture()

            XCTAssertEqual(fixture.seeks, [22.5])
            XCTAssertEqual(fixture.begins, 1)
            XCTAssertEqual(fixture.ends, 1)
            XCTAssertFalse(fixture.interaction.isEditing)
            fixture.publish()
            XCTAssertEqual(fixture.slider.doubleValue, 22.5)
            XCTAssertEqual(fixture.slider.maxValue, 91)
            XCTAssertEqual(try accessibleValue(fixture.slider), 22.5)
        }
    }

    func testExternalSeekCancelsHeldDragAndRestoresPausedMeasuredValueWithoutAnotherSample() throws {
        let fixture = Fixture(playing: true, position: 70)
        defer { fixture.stop() }
        let originalGeneration = fixture.generation
        XCTAssertTrue(fixture.slider.beginTrackingGesture())
        fixture.sendNativeAction(50)
        fixture.measured = 80; fixture.seekRevision += 1; fixture.playing = false
        fixture.publish(queuedValue: 50)
        XCTAssertEqual(fixture.generation, originalGeneration)
        XCTAssertTrue(fixture.slider.trackingCancelled)
        XCTAssertEqual(fixture.slider.renderedPosition, 80, "Cancelled tracking must display the authoritative seek, not its former draft.")
        fixture.sendNativeAction(30) // AppKit can still finish processing the held mouse gesture.
        XCTAssertEqual(fixture.slider.doubleValue, 30)
        XCTAssertEqual(fixture.slider.renderedPosition, 80)

        fixture.slider.finishTrackingGesture()

        XCTAssertTrue(fixture.seeks.isEmpty, "A same-occurrence external seek must not be overwritten by an old draft on release.")
        XCTAssertEqual(fixture.cancellations, 1)
        XCTAssertEqual(fixture.ends, 1)
        XCTAssertEqual(fixture.slider.doubleValue, 80, "Paused playback may never publish another sample to repair a stale native value.")
        XCTAssertEqual(fixture.slider.renderedPosition, 80)
        XCTAssertEqual(try accessibleValue(fixture.slider), 80)
    }

    func testTrackReplacementCancelsDraftAndUnmovedTouchDoesNotSeek() {
        let fixture = Fixture(playing: true, position: 20)
        defer { fixture.stop() }
        XCTAssertTrue(fixture.slider.beginTrackingGesture())
        fixture.sendNativeAction(40)
        fixture.generation = UUID(); fixture.measured = 3
        fixture.publish(queuedValue: 40)
        fixture.sendNativeAction(60)
        fixture.slider.finishTrackingGesture()
        XCTAssertTrue(fixture.seeks.isEmpty)
        XCTAssertEqual(fixture.slider.doubleValue, 3)
        XCTAssertEqual(fixture.cancellations, 1)

        XCTAssertTrue(fixture.slider.beginTrackingGesture())
        fixture.sendNativeAction(3) // Native controls may send an action even without movement.
        fixture.measured = 3.2
        fixture.publish(queuedValue: 3.2)
        fixture.slider.finishTrackingGesture()
        XCTAssertTrue(fixture.seeks.isEmpty)
        XCTAssertEqual(fixture.slider.doubleValue, 3.2)
    }

    func testRunningClockAdvancesOnlyThePaintedThumbAtExactlyRealTimeRate() throws {
        let slider = BufferedTimelineSlider.makeSlider()
        slider.minValue = 0; slider.maxValue = 100
        let generation = UUID()
        defer { slider.stopPresentationUpdates() }
        let clock = PlaybackClock(position: 10, uptime: 50, isRunning: true)
        slider.applyPlaybackPosition(10, clock: clock, generation: generation, seekRevision: 0, at: 50)
        for time in [50.016, 50.5, 51.25] {
            slider.advancePresentation(to: time)
            XCTAssertEqual(slider.renderedPosition, 10 + (time - 50), accuracy: 1e-9, "Every frame sits on one real-time line.")
        }
        // A 5 Hz publication from the same running clock neither restarts nor bends the motion.
        slider.applyPlaybackPosition(11.2, clock: clock, generation: generation, seekRevision: 0, at: 51.3)
        XCTAssertEqual(slider.renderedPosition, 11.3, accuracy: 1e-9)
        XCTAssertEqual(slider.doubleValue, 11.2, "Native input and accessibility keep the published value.")
        XCTAssertEqual(try accessibleValue(slider), 11.2, accuracy: 0.0001)

        slider.applyPlaybackPosition(11.4, clock: PlaybackClock(position: 11.4, uptime: 51.4, isRunning: false),
                                     generation: generation, seekRevision: 0, at: 51.4)
        slider.advancePresentation(to: 60)
        XCTAssertEqual(slider.renderedPosition, 11.4, "A stopped clock stands still.")
    }

    private func accessibleValue(_ slider: TimelineSlider) throws -> Double {
        let element = try XCTUnwrap(slider.accessibilityChildren()?.compactMap { $0 as? NSSliderCell }.first)
        return try XCTUnwrap(element.accessibilityValue() as? NSNumber).doubleValue
    }

    private func host(_ slider: TimelineSlider, width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: PlaybackTimelineMetrics.interactionHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        slider.frame = NSRect(x: 0, y: 0, width: width, height: PlaybackTimelineMetrics.interactionHeight)
        window.contentView?.addSubview(slider)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private final class Fixture {
        let slider = BufferedTimelineSlider.makeSlider()
        var interaction = PlaybackSeekInteraction()
        var generation = UUID()
        var seekRevision: UInt64 = 0
        var measured: Double
        var duration: Double = 90
        var playing: Bool
        var seeks: [Double] = []
        var begins = 0, ends = 0, cancellations = 0
        var onDraftChanged: (() -> Void)?
        var coordinator: BufferedTimelineSlider.Coordinator!

        init(playing: Bool, position: Double) {
            _ = NSApplication.shared
            self.playing = playing; measured = position
            coordinator = component.makeCoordinator()
            coordinator.connect(slider)
            publish()
        }

        var component: BufferedTimelineSlider {
            BufferedTimelineSlider(value: Binding(get: { [self] in interaction.isEditing ? interaction.position ?? measured : measured },
                set: { [self] in interaction.change(to: $0, generation: generation); onDraftChanged?() }),
                duration: duration, ranges: [], enabled: true, showsBuffer: false,
                onEditingChanged: { [self] editing in
                    if editing { begins += 1; interaction.begin(at: measured, generation: generation) }
                    else {
                        ends += 1
                        if let target = interaction.end(generation: generation) { seeks.append(target); measured = target; seekRevision += 1 }
                    }
                }, animatesPlayback: playing, playbackGeneration: generation, seekRevision: seekRevision,
                onEditingCancelled: { [self] in cancellations += 1; interaction.cancel() }, measuredPosition: measured)
        }

        func publish(queuedValue: Double? = nil) {
            coordinator.parent = component
            slider.updatePlayback(position: queuedValue ?? (interaction.isEditing ? interaction.position ?? measured : measured),
                measuredPosition: measured, duration: duration, enabled: true,
                clock: playing && !interaction.isEditing
                    ? PlaybackClock(position: measured, uptime: ProcessInfo.processInfo.systemUptime, isRunning: true) : nil,
                generation: generation, seekRevision: seekRevision)
        }

        func stop() { slider.stopPresentationUpdates(); onDraftChanged = nil; coordinator = nil }

        func sendNativeAction(_ value: Double) {
            slider.doubleValue = value
            _ = slider.sendAction(slider.action, to: slider.target)
        }
    }
}
