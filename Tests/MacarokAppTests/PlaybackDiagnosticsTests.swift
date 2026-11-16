import AppKit
import MacarokAudio
import MacarokCore
import SwiftUI
import XCTest
@testable import MacarokApp

@MainActor
final class PlaybackDiagnosticsTests: XCTestCase {
    private let occurrence = UUID()
    private func sample(_ time: Double, phase: PlaybackWatchdog.Phase = .playing,
                        position: Double? = 20, output: UInt64? = nil) -> PlaybackWatchdog.Sample {
        .init(occurrenceID: occurrence, monotonicTime: time, phase: phase, position: position, audioOutputCounter: output)
    }

    func testControllerPublishesActualStreamCountersAndLogsOnlyChangedWaitCount() throws {
        let controller = PlaybackDiagnosticsController()
        let engine = VLCPlaybackEngine()
        let first = StreamBufferSnapshot(bufferedBytes: 512, targetBytes: 1024, totalBytes: nil,
            offset: 80, isBuffering: false, isFinished: false, capacityBytes: 4096, underrunCount: 1, readerWaitDuration: 0.25)
        controller.observe(sample(0), engine: engine.diagnostics, stream: first, media: .podcast, duration: 100)
        let second = StreamBufferSnapshot(bufferedBytes: 128, targetBytes: 1024, totalBytes: nil,
            offset: 464, isBuffering: false, isFinished: false, capacityBytes: 4096, underrunCount: 3, readerWaitDuration: 2.75)
        controller.observe(sample(1, position: 21), engine: engine.diagnostics, stream: second, media: .podcast, duration: 100)
        controller.observe(sample(2, position: 22), engine: engine.diagnostics, stream: second, media: .podcast, duration: 100)
        let metrics = try XCTUnwrap(controller.snapshot?.metrics)
        XCTAssertEqual(metrics.bufferedBytes, 128)
        XCTAssertEqual(metrics.bufferCapacityBytes, 4096)
        XCTAssertEqual(metrics.underrunCount, 3)
        XCTAssertEqual(metrics.readerWaitSeconds, 2.75)
        XCTAssertEqual(metrics.duration, 100)
        XCTAssertEqual(metrics.installationCount, engine.diagnostics.installationCount)
        XCTAssertEqual(controller.events.filter { $0.kind == .underrun }.count, 2)
        XCTAssertEqual(controller.events.filter { $0.kind == .occurrenceStarted }.count, 1)
        XCTAssertEqual(controller.events.filter { $0.kind == .phaseChanged }.count, 1)
    }

    func testClearingDiagnosticsDoesNotPermitAnotherWatchdogRecoveryForTheSameOccurrence() {
        let controller = PlaybackDiagnosticsController()
        let engine = VLCPlaybackEngine()
        var incidents = 0
        for time in 0...12 {
            if controller.observe(sample(Double(time)), engine: engine.diagnostics, stream: nil) != nil { incidents += 1 }
        }
        XCTAssertEqual(incidents, 1)
        XCTAssertEqual(controller.events.last?.kind, .watchdog)
        controller.clearEvents()
        for time in 13...50 {
            XCTAssertNil(controller.observe(sample(Double(time)), engine: engine.diagnostics, stream: nil))
        }
        XCTAssertTrue(controller.events.isEmpty)
    }

    func testExplicitSeekUpdatesMonitorImmediatelyAndIsVisibleInEventHistory() {
        let controller = PlaybackDiagnosticsController()
        let engine = VLCPlaybackEngine()
        for time in 0...10 { XCTAssertNil(controller.observe(sample(Double(time)), engine: engine.diagnostics, stream: nil)) }
        controller.markSeek(occurrenceID: occurrence, monotonicTime: 10)
        for time in 11...30 { XCTAssertNil(controller.observe(sample(Double(time), position: 80), engine: engine.diagnostics, stream: nil)) }
        XCTAssertNotNil(controller.observe(sample(31, position: 80), engine: engine.diagnostics, stream: nil))
        XCTAssertEqual(controller.events.filter { $0.kind == .seek }.count, 1)
    }

    func testMissingLiveClockIsExplicitAndExportIncludesCurrentSnapshotAndBoundedTypedLog() throws {
        let controller = PlaybackDiagnosticsController(capacity: 3)
        let engine = VLCPlaybackEngine()
        for time in 0...50 {
            XCTAssertNil(controller.observe(sample(Double(time), position: nil), engine: engine.diagnostics, stream: nil, media: .radio))
        }
        XCTAssertEqual(controller.events.filter { $0.kind == .monitoringUnavailable }.count, 1)
        XCTAssertEqual(controller.snapshot?.hasProgressSignal, false)
        for _ in 0..<4 { controller.record(.upcomingCancelled, occurrenceID: occurrence, media: .radio) }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: controller.exportData(at: Date(timeIntervalSince1970: 10))) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let snapshot = try XCTUnwrap(object["snapshot"] as? [String: Any])
        XCTAssertEqual(snapshot["media"] as? String, "radio")
        XCTAssertEqual(snapshot["hasProgressSignal"] as? Bool, false)
        let log = try XCTUnwrap(object["log"] as? [String: Any])
        XCTAssertEqual((log["events"] as? [Any])?.count, 3)
        XCTAssertGreaterThan(controller.droppedEntries, 0)
        let text = String(decoding: try controller.exportData(), as: UTF8.self).lowercased()
        for forbidden in ["https://", "file://", "credential", "password", "filepath", "tracktitle", "localizeddescription"] {
            XCTAssertFalse(text.contains(forbidden))
        }
    }

    func testNativeDiagnosticsRendersLightAndDarkWithoutOpeningAWindow() async throws {
        _ = NSApplication.shared
        let controller = PlaybackDiagnosticsController()
        let engine = VLCPlaybackEngine()
        controller.observe(sample(0, output: 40), engine: engine.diagnostics,
            stream: .init(bufferedBytes: 512_000, targetBytes: 1_024_000, totalBytes: nil, offset: 100,
                isBuffering: false, isFinished: false, capacityBytes: 4_194_304, underrunCount: 2, readerWaitDuration: 1.25),
            media: .podcast, duration: 1800)
        controller.record(.nativeHandoff, occurrenceID: occurrence, phase: .playing, media: .podcast,
                          metrics: .init(position: 0, transitionSeconds: 0.042))
        for scheme in [ColorScheme.light, .dark] {
            let hosting = NSHostingView(rootView: PlaybackDiagnosticsView(controller: controller).environment(\.colorScheme, scheme))
            hosting.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            hosting.sizingOptions = []; hosting.frame = NSRect(x: 0, y: 0, width: 820, height: 600)
            let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            window.contentView = hosting
            for _ in 0..<8 { hosting.layoutSubtreeIfNeeded(); await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            XCTAssertEqual(bitmap.pixelsWide, Int(hosting.bounds.width * window.backingScaleFactor))
            XCTAssertFalse(window.isVisible)
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 2, y: 2)).alphaComponent, 0.99,
                                 "The diagnostics surface must draw its own native background in exported previews.")
            if let path = ProcessInfo.processInfo.environment["MACAROK_SNAPSHOT_DIRECTORY"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("playback-diagnostics-\(scheme == .light ? "light" : "dark").png"))
            }
            window.contentView = nil; window.close()
        }
    }
}
