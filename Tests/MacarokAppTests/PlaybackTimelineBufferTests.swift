import AppKit
@testable import MacarokCore
import SwiftUI
import XCTest
@testable import MacarokApp

@MainActor
final class PlaybackTimelineBufferTests: XCTestCase {
    func testByteRangesKeepHolesAndDoNotInventADownloadedPrefix() {
        let snapshot = makeSnapshot(total: 1000, ranges: [200..<350, 600..<800], offset: 620, buffered: 180)
        let ranges = PlaybackTimelineView.normalizedRanges(snapshot)
        XCTAssertEqual(ranges, [0.2..<0.35, 0.6..<0.8])
        XCTAssertFalse(ranges.contains { $0.contains(0.1) })
        XCTAssertFalse(ranges.contains { $0.contains(0.5) })
    }

    func testRangesAreClampedToTheRepresentationAndEmptyRangesAreIgnored() {
        let snapshot = makeSnapshot(total: 1000, ranges: [0..<100, 900..<1200, 500..<500, 1400..<1500])
        XCTAssertEqual(PlaybackTimelineView.normalizedRanges(snapshot), [0..<0.1, 0.9..<1])
        XCTAssertEqual(PlaybackTimelineView.normalizedRanges(makeSnapshot(total: 1000, ranges: [0..<1000])), [0..<1])
    }

    func testUnknownOrInvalidTotalsCannotClaimAnAudioTimeRange() {
        for total in [Int64?.none, 0, -1] {
            XCTAssertTrue(PlaybackTimelineView.normalizedRanges(makeSnapshot(total: total, ranges: [0..<1000])).isEmpty)
        }
        XCTAssertTrue(PlaybackTimelineView.normalizedRanges(makeSnapshot(total: 1000, ranges: [], offset: 500, buffered: 500)).isEmpty)
        XCTAssertTrue(PlaybackTimelineView.normalizedRanges(makeSnapshot(total: 1000, ranges: [(UInt64.max - 1)..<UInt64.max])).isEmpty)
    }

    func testNativeTimelineDrawsPlayedBufferedAndUnavailableSegmentsInBothAppearances() async throws {
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            try await verifyColors(BufferedTimelineSlider(value: .constant(25), duration: 100,
                ranges: [0.2..<0.8], enabled: true, showsBuffer: true, onEditingChanged: { _ in }),
                scheme: scheme, bufferedAt: 0.55, unavailableAt: 0.9, name: "podcast-timeline")
        }
    }

    func testCompletedDownloadShowsFullCoverageThroughTheControllerAndTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokDownloadedTimeline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let track = TrackRecord(id: "downloaded-timeline-track", sourceID: "podcast", title: "Downloaded episode",
                                artist: "Macarok", album: "Test podcast", duration: 100, fileURL: "https://podcast.invalid/episode.mp3")
        let key = PodcastDownloadStore.key(sourceID: track.sourceID, trackID: track.id)
        let record = PodcastDownload(id: key, sourceID: track.sourceID, trackID: track.id, title: track.title,
                                     filename: "\(key).mp3", byteCount: 4, downloadedAt: Date())
        let file = directory.appendingPathComponent(record.filename)
        try Data([0, 0, 0, 0]).write(to: file)
        try JSONEncoder().encode([record]).write(to: directory.appendingPathComponent("downloads.json"))
        let model = AppModel(preferences: AppPreferences(), registerSystemControls: false)
        model.sources = [SourceRecord(id: track.sourceID, kind: .podcasts, name: "Test Podcast", location: "https://podcast.invalid/feed.xml")]
        model.queue = [QueueItem(track: track)]; model.currentQueueID = model.queue[0].id
        let controller = PodcastDownloadsController(model: model, directory: directory)
        model.podcastDownloads = controller
        await controller.start()
        XCTAssertEqual(controller.localURL(for: track), file)
        XCTAssertFalse(controller.isDownloading(track))
        // Install an unopened local media object to seed a stable clock without network or decoding.
        model.player.load(url: file, durationHint: 100, autoplay: false)
        model.player.seek(to: 25)
        defer { model.player.stop() }
        XCTAssertEqual(model.player.position, 25)
        for scheme in [ColorScheme.light, .dark] {
            try await verifyColors(PlaybackTimelineView(model: model, timeline: model.player.timeline, track: track),
                scheme: scheme, bufferedAt: 0.9, unavailableAt: nil, name: "podcast-timeline-downloaded")
        }
        XCTAssertEqual(controller.localURL(for: track), file)
    }

    private func verifyColors<Content: View>(_ content: Content, scheme: ColorScheme,
                                             bufferedAt: CGFloat, unavailableAt: CGFloat?, name: String) async throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: content.frame(width: 420, height: 30)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme).environment(\.layoutDirection, .leftToRight))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 30)
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        for _ in 0..<12 { hosting.layoutSubtreeIfNeeded(); await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
        let slider = try XCTUnwrap(findSlider(in: hosting))
        XCTAssertEqual(slider.accessibilityIdentifier(), "playbackTimeline")
        XCTAssertEqual(slider.doubleValue, 25, accuracy: 0.01)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["MACAROK_SNAPSHOT_DIRECTORY"], let png = bitmap.representation(using: .png, properties: [:]) {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("\(name)-\(scheme == .light ? "light" : "dark").png"))
        }
        let cell = try XCTUnwrap(slider.cell as? NSSliderCell)
        let bar = slider.convert(cell.barRect(flipped: slider.isFlipped), to: hosting)
        let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        func pixelX(_ fraction: CGFloat) -> Int { Int((bar.minX + bar.width * fraction) * scale) }
        // Locate the painted row from the played column, independent of bitmap Y orientation.
        let rows = (0..<bitmap.pixelsHigh).filter { y in
            guard let color = bitmap.colorAt(x: pixelX(0.1), y: y)?.usingColorSpace(.sRGB) else { return false }
            return color.blueComponent > color.redComponent + 0.25 && color.blueComponent > color.greenComponent + 0.15
        }
        XCTAssertFalse(rows.isEmpty, "The played portion must remain blue in both appearances.")
        guard !rows.isEmpty else { return }
        let row = rows[rows.count / 2]
        let white = try XCTUnwrap(bitmap.colorAt(x: pixelX(bufferedAt), y: row)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(min(white.redComponent, white.greenComponent, white.blueComponent), 0.94, "Buffered audio must have a white center.")
        if let unavailableAt {
            let gray = try XCTUnwrap(bitmap.colorAt(x: pixelX(unavailableAt), y: row)?.usingColorSpace(.sRGB))
            XCTAssertLessThan(abs(gray.redComponent - gray.greenComponent), 0.06)
            XCTAssertLessThan(abs(gray.greenComponent - gray.blueComponent), 0.06)
            XCTAssertGreaterThan(white.brightnessComponent - gray.brightnessComponent, 0.06, "Buffered and unavailable audio must remain distinguishable in Light and Dark.")
        }
        XCTAssertFalse(window.isVisible)

    }

    private func makeSnapshot(total: Int64?, ranges: [Range<UInt64>], offset: UInt64 = 0, buffered: Int = 0) -> StreamBufferSnapshot {
        StreamBufferSnapshot(bufferedBytes: buffered, targetBytes: 128_000, totalBytes: total, offset: offset,
                             isBuffering: false, isFinished: false, retainedRanges: ranges)
    }
    private func findSlider(in view: NSView) -> TimelineSlider? {
        (view as? TimelineSlider) ?? view.subviews.lazy.compactMap { self.findSlider(in: $0) }.first
    }
}
