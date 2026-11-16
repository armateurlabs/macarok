import AppKit
import MacarokCore
import SwiftUI
import XCTest
@testable import MacarokApp

/// Resolves native event receivers through the real SwiftUI transport hierarchy, without choosing
/// TimelineSlider directly or forcing enabled state. Hidden NSWindows suppress sendEvent dispatch.
@MainActor
final class PlaybackTimelineRoutingTests: XCTestCase {
    func testFullTransportRoutesClicksAndBothDragDirectionsForDecodedLocalAndStreamAudio() async throws {
        _ = NSApplication.shared
        for backend in [Backend.local, .stream] {
            let fixture = try Fixture(backend: backend)
            defer { fixture.stop() }
            try await eventually { fixture.model.player.state == .playing && fixture.model.player.isSeekable }
            for paused in [false, true] {
                if paused {
                    fixture.model.pausePlayback()
                    try await eventually { fixture.model.player.state == .paused }
                }
                for scheme in [ColorScheme.light, .dark] {
                    let host = Host(model: fixture.model, scheme: scheme)
                    defer { host.close() }
                    try await host.settle()
                    let slider = try XCTUnwrap(findSlider(in: host.hosting))
                    XCTAssertTrue(fixture.model.player.isSeekable)
                    XCTAssertTrue(slider.isEnabled, "The full view must derive enabled state from a decoded, seekable engine.")
                    XCTAssertEqual(slider.bounds.height, 32, accuracy: 0.01)
                    for fraction in [CGFloat(0.1), 0.5, 0.9] {
                        for verticalOffset in [CGFloat(-15), 0, 15] {
                            try host.assertRouted(to: slider, at: NSPoint(x: slider.playbackTrackRect.minX + slider.playbackTrackRect.width * fraction,
                                                                        y: slider.playbackTrackRect.midY + verticalOffset))
                        }
                    }

                    let revision = fixture.model.player.timeline.seekRevision
                    try host.click(slider, fraction: 0.25, verticalOffset: 15)
                    try await host.settle()
                    XCTAssertGreaterThan(fixture.model.player.timeline.seekRevision, revision,
                                         "A routed bar click must reach the real PlaybackSeekInteraction and engine seek callback.")
                    XCTAssertEqual(fixture.model.player.position, 22.5, accuracy: 1)
                    try host.drag(slider, to: 0.75, verticalOffset: -15)
                    try await host.settle()
                    XCTAssertEqual(fixture.model.player.position, 67.5, accuracy: 1)
                    try host.drag(slider, to: 0.1, verticalOffset: 15)
                    try await host.settle()
                    XCTAssertEqual(fixture.model.player.position, 9, accuracy: 1)
                    if paused { XCTAssertEqual(fixture.model.player.state, .paused) }
                    XCTAssertFalse(host.window.isVisible)
                }
            }
        }
    }

    func testFullTransportKeepsUnseekableStreamDisabledWithoutCommittingAClick() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(backend: .unseekableStream)
        defer { fixture.stop() }
        try await eventually { fixture.model.player.state == .playing && fixture.model.player.duration > 0 }
        let host = Host(model: fixture.model, scheme: .dark)
        defer { host.close() }
        try await host.settle()
        let slider = try XCTUnwrap(findSlider(in: host.hosting))
        XCTAssertFalse(fixture.model.player.isSeekable)
        XCTAssertFalse(slider.isEnabled)
        let revision = fixture.model.player.timeline.seekRevision
        try host.click(slider, fraction: 0.75, verticalOffset: 0)
        try await host.settle()
        XCTAssertEqual(fixture.model.player.timeline.seekRevision, revision)
        XCTAssertLessThan(fixture.model.player.position, 10)
    }

    func testRestoredEntryTimelineMovesItsResumePointWithoutStartingPlayback() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(backend: .restored)
        defer { fixture.stop() }
        let host = Host(model: fixture.model, scheme: .light)
        defer { host.close() }
        try await host.settle()
        let slider = try XCTUnwrap(findSlider(in: host.hosting))
        XCTAssertTrue(slider.isEnabled, "A restored entry must accept a new start point before VLC loads it.")
        let revision = fixture.model.player.timeline.seekRevision
        try host.click(slider, fraction: 0.25, verticalOffset: 0)
        try await host.settle()
        XCTAssertEqual(fixture.model.restorePosition, 22.5, accuracy: 1)
        XCTAssertEqual(fixture.model.player.state, .stopped)
        XCTAssertEqual(fixture.model.player.timeline.seekRevision, revision)
    }

    private func findSlider(in view: NSView) -> TimelineSlider? {
        if let slider = view as? TimelineSlider, slider.accessibilityIdentifier() == "playbackTimeline" { return slider }
        return view.subviews.lazy.compactMap { self.findSlider(in: $0) }.first
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.timeout
    }

    private enum Backend { case local, stream, unseekableStream, restored }
    private enum Failure: Error { case timeout, hit(String) }

    @MainActor
    private final class Host {
        let hosting: NSHostingView<AnyView>
        let window: NSWindow
        private var eventTime = ProcessInfo.processInfo.systemUptime

        init(model: AppModel, scheme: ColorScheme) {
            hosting = NSHostingView(rootView: AnyView(TransportBar(model: model, player: model.player)
                .frame(width: 1200, height: 90).environment(\.colorScheme, scheme)))
            hosting.sizingOptions = []
            hosting.frame = NSRect(x: 0, y: 0, width: 1200, height: 90)
            window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            window.contentView = hosting
        }

        func close() { window.contentView = nil; window.close() }

        func settle() async throws {
            for _ in 0..<12 {
                hosting.layoutSubtreeIfNeeded()
                await Task.yield()
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        @discardableResult
        func assertRouted(to slider: TimelineSlider, at point: NSPoint) throws -> NSView {
            let windowPoint = slider.convert(point, to: nil)
            let parentPoint = hosting.superview?.convert(windowPoint, from: nil) ?? windowPoint
            let hit = hosting.hitTest(parentPoint)
            guard let hit, hit === slider || hit.isDescendant(of: slider) else {
                throw Failure.hit("Transport hit \(hit.map { String(reflecting: type(of: $0)) } ?? "nil") instead of timeline at \(point); slider frame \(slider.frame), bounds \(slider.bounds), enabled \(slider.isEnabled)")
            }
            return hit
        }

        func click(_ slider: TimelineSlider, fraction: CGFloat, verticalOffset: CGFloat) throws {
            eventTime = ProcessInfo.processInfo.systemUptime
            let point = NSPoint(x: slider.playbackTrackRect.minX + slider.playbackTrackRect.width * fraction,
                                y: slider.playbackTrackRect.midY + verticalOffset)
            let receiver = try assertRouted(to: slider, at: point)
            let down = try event(.leftMouseDown, slider: slider, point: point, number: 1)
            let up = try event(.leftMouseUp, slider: slider, point: point, number: 2)
            if slider.isEnabled {
                window.postEvent(up, atStart: false)
                receiver.mouseDown(with: down)
            } else {
                receiver.mouseDown(with: down); receiver.mouseUp(with: up)
            }
            drainMouseEvents()
        }

        func drag(_ slider: TimelineSlider, to fraction: CGFloat, verticalOffset: CGFloat) throws {
            eventTime = ProcessInfo.processInfo.systemUptime
            let start = NSPoint(x: slider.playbackThumbRect.midX, y: slider.playbackThumbRect.midY)
            let end = NSPoint(x: slider.playbackTrackRect.minX + slider.playbackTrackRect.width * fraction,
                              y: slider.playbackTrackRect.midY + verticalOffset)
            let receiver = try assertRouted(to: slider, at: start)
            try assertRouted(to: slider, at: end)
            let middle = NSPoint(x: (start.x + end.x) / 2, y: slider.playbackTrackRect.midY)
            window.postEvent(try event(.leftMouseDragged, slider: slider, point: middle, number: 2), atStart: false)
            window.postEvent(try event(.leftMouseUp, slider: slider, point: end, number: 3), atStart: false)
            receiver.mouseDown(with: try event(.leftMouseDown, slider: slider, point: start, number: 1))
            drainMouseEvents()
        }

        private func event(_ type: NSEvent.EventType, slider: TimelineSlider, point: NSPoint, number: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: slider.convert(point, to: nil), modifierFlags: [],
                timestamp: eventTime + Double(number) / 1000, windowNumber: window.windowNumber, context: nil, eventNumber: number,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }

        private func drainMouseEvents() {
            for _ in 0..<10 {
                guard window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date(),
                                       inMode: .eventTracking, dequeue: true) != nil else { break }
            }
        }
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let model: AppModel

        init(backend: Backend) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokRoutedTimeline-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("timeline.wav")
            try Self.wave().write(to: file)
            var preferences = AppPreferences(); preferences.volume = 0
            model = AppModel(preferences: preferences, registerSystemControls: false)
            let source = SourceRecord(id: "timeline-routing", kind: [.local, .restored].contains(backend) ? .local : .podcasts,
                                      name: "Timeline Routing", location: directory.absoluteString)
            let track = TrackRecord(id: "timeline-routing-track", sourceID: source.id, title: "Timeline Routing",
                                    artist: "Macarok", album: "Input Tests", duration: 90, fileURL: file.absoluteString)
            model.sources = [source]
            model.queue = [QueueItem(track: track)]; model.currentQueueID = model.queue[0].id
            if backend == .restored { return }
            if backend == .local { model.player.load(url: file, durationHint: 90) }
            else {
                let stream = try XCTUnwrap(InputStream(url: file))
                model.player.load(stream: stream, durationHint: 90, supportsSeeking: { backend == .stream })
            }
        }

        func stop() { model.stopPlayback(clearCurrent: true); try? FileManager.default.removeItem(at: directory) }

        private static func wave() -> Data {
            let sampleRate = 8_000, size = 90 * sampleRate * 2
            var data = Data("RIFF".utf8)
            func word<T: FixedWidthInteger>(_ value: T) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            word(UInt32(size + 36)); data.append(Data("WAVEfmt ".utf8))
            word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(sampleRate)); word(UInt32(sampleRate * 2))
            word(UInt16(2)); word(UInt16(16)); data.append(Data("data".utf8)); word(UInt32(size)); data.append(Data(count: size))
            return data
        }
    }
}
