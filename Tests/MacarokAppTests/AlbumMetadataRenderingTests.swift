import AppKit
import Foundation
import MacarokCore
import SwiftUI
import XCTest
@testable import MacarokApp

/// Exercises the real center panel without opening windows, starting playback, or contacting a source.
@MainActor
final class AlbumMetadataRenderingTests: XCTestCase {
    func testAlbumEditorSharedFieldsAndPinnedDraftRenderAtNarrowAndWideWidths() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokAlbumRendering-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let source = SourceRecord(id: "album-render-source", kind: .openSubsonic, name: "Album Preview Library", location: "https://preview.invalid")
        let first = TrackRecord(id: "album-render-first", sourceID: source.id, albumID: "album-render", title: "TRACK_TITLE_ONE_MUST_STAY_READ_ONLY",
            artist: "Original performer one", albumArtist: "Original album artist", album: "Original Preview Album", year: 2001,
            genre: "Original Genre", trackNumber: 17, discNumber: 9, duration: 180, format: "FLAC")
        let second = TrackRecord(id: "album-render-second", sourceID: source.id, albumID: first.albumID, title: "TRACK_TITLE_TWO_MUST_STAY_READ_ONLY",
            artist: "Original performer two", albumArtist: first.albumArtist, album: first.album, year: first.year,
            genre: first.genre, trackNumber: 18, discNumber: 9, duration: 181, format: "FLAC")
        try store.saveSource(source)
        try store.upsertTracks([first, second])
        let model = AppModel(store: store, preferences: AppPreferences(), registerSystemControls: false)
        model.sources = [source]
        model.queue = [QueueItem(track: first), QueueItem(track: second)]
        model.currentQueueID = model.queue[0].id
        model.centerPage = .playing
        model.beginAlbumMetadataEditing(first)
        let session = try XCTUnwrap(model.albumMetadataEditingSession)
        await model.loadAlbumMetadata(session: session)
        XCTAssertEqual(session.tracks.count, 2)
        session.draft.album = "Edited Album Draft"
        session.draft.year = "2027"
        session.draft.genre = "Edited Jazz"
        model.currentQueueID = model.queue[1].id
        XCTAssertEqual(model.contextMode, .editAlbumMetadata)
        XCTAssertTrue(model.albumMetadataEditingSession === session)
        XCTAssertEqual(session.track.id, first.id)

        let output = try snapshotDirectory()
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(370), 590] {
                try await render(model: model, session: session, width: width, scheme: scheme, output: output)
                XCTAssertEqual(session.draft.album, "Edited Album Draft")
                XCTAssertEqual(session.track.id, first.id)
                XCTAssertEqual(model.currentTrack?.id, second.id)
            }
        }
        XCTAssertEqual(model.player.state, .stopped)
    }

    private func render(model: AppModel, session: AlbumMetadataEditingSession, width: CGFloat, scheme: ColorScheme, output: URL?) async throws {
        let size = NSSize(width: width, height: 860)
        let appearance = try XCTUnwrap(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
        let hosting = NSHostingView(rootView: ContextPane(model: model)
            .frame(width: width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.layoutDirection, .leftToRight))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = appearance
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        window.setContentSize(size)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<12 {
            hosting.layoutSubtreeIfNeeded()
            await Task.yield()
            try await Task.sleep(for: .milliseconds(20))
        }
        let fields: [NSTextField] = descendants(in: hosting).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertEqual(fields.count, 5, "Album editing exposes only the five shared metadata fields.")
        XCTAssertEqual(Set(fields.map(\.stringValue)), [session.draft.album, session.draft.albumArtist, session.draft.artist, session.draft.year, session.draft.genre])
        XCTAssertFalse(fields.contains { $0.stringValue.hasPrefix("TRACK_TITLE_") || ["17", "18", "9"].contains($0.stringValue) },
                       "Track title, track number, and disc number must never become editable album fields.")
        for field in fields {
            let frame = field.convert(field.bounds, to: hosting)
            XCTAssertGreaterThan(frame.width, 20)
            XCTAssertGreaterThan(frame.height, 10)
            XCTAssertGreaterThanOrEqual(frame.minX, -1)
            XCTAssertLessThanOrEqual(frame.maxX, width + 1)
            let identifier = field.accessibilityIdentifier()
            XCTAssertFalse(["title", "tracknumber", "discnumber"].contains(identifier.lowercased()))
        }

        let controls: [NSSegmentedControl] = descendants(in: hosting).compactMap { $0 as? NSSegmentedControl }
        let primary = try XCTUnwrap(controls.first { $0.segmentCount == 2 && $0.label(forSegment: 0) == "Home" })
        let fullTitles = ContextMode.allCases.map(\.title)
        let secondary = try XCTUnwrap(controls.first { $0.segmentCount == fullTitles.count && $0.label(forSegment: 0) == "Context" })
        XCTAssertEqual(primary.selectedSegment, 1)
        XCTAssertEqual(secondary.selectedSegment, ContextMode.allCases.firstIndex(of: .editAlbumMetadata))
        let compactTitles = ["Edit song metadata": "Song metadata", "Edit album metadata": "Album metadata"]
        for (index, fullTitle) in fullTitles.enumerated() {
            let displayed = try XCTUnwrap(secondary.label(forSegment: index))
            XCTAssertTrue(displayed == fullTitle || displayed == compactTitles[fullTitle], "The native segment must retain its full or readable compact English title.")
            XCTAssertEqual(secondary.toolTip(forSegment: index), fullTitle, "Compact display labels must retain their full native tooltip.")
            XCTAssertTrue(secondary.accessibilityHelp()?.contains(fullTitle) == true, "The full mode names must remain available to accessibility clients.")
            if width == 590 { XCTAssertEqual(displayed, fullTitle, "Wide panels should retain the complete mode names.") }
        }
        let frames = [primary, secondary].map { $0.convert($0.bounds, to: hosting) }.sorted { $0.midY < $1.midY }
        XCTAssertEqual(frames[1].midY - frames[0].midY, 43, accuracy: 1)
        for frame in frames {
            XCTAssertEqual(frame.midX, width / 2, accuracy: 1)
            XCTAssertGreaterThanOrEqual(frame.minX, -1)
            XCTAssertLessThanOrEqual(frame.maxX, width + 1)
        }
        let font = secondary.font ?? .systemFont(ofSize: 10.5)
        XCTAssertGreaterThanOrEqual(font.pointSize, 10, "Compact labels must remain readable at the minimum panel width.")
        let labelsWidth = (0..<fullTitles.count).reduce(CGFloat(0)) { total, index in
            total + ((secondary.label(forSegment: index) ?? "") as NSString).size(withAttributes: [.font: font]).width
        }
        XCTAssertLessThanOrEqual(labelsWidth + CGFloat(fullTitles.count * 12), secondary.bounds.width + 1, "Every English label must fit the native segmented control.")

        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 4_096)
        XCTAssertGreaterThan(sampledColorCount(bitmap), 2, "The album editor must not render a blank bitmap.")
        if let output {
            let suffix = scheme == .light ? "light" : "dark"
            let narrow = width == 370 ? "narrow-" : ""
            try data.write(to: output.appendingPathComponent("album-metadata-\(narrow)\(suffix).png"), options: .atomic)
        }
        XCTAssertFalse(window.isVisible)
    }

    private func descendants(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants(in: $0) } }

    private func sampledColorCount(_ bitmap: NSBitmapImageRep) -> Int {
        var colors = Set<String>()
        for row in 0..<40 {
            for column in 0..<40 {
                let x = min(bitmap.pixelsWide - 1, column * max(1, bitmap.pixelsWide - 1) / 39)
                let y = min(bitmap.pixelsHigh - 1, row * max(1, bitmap.pixelsHigh - 1) / 39)
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                }
            }
        }
        return colors.count
    }

    private func snapshotDirectory() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["MACAROK_SNAPSHOT_DIRECTORY"], !path.isEmpty else { return nil }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
