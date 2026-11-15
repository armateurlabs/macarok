import AppKit
import Foundation
import MacarokCore
import MacarokMetadata
import SwiftUI
import XCTest
@testable import MacarokApp

/// Explicitly enabled software renders of native components, not screen captures or UI interaction tests.
@MainActor
final class NativeRenderingTests: XCTestCase {
    func testRenderDemoComponentsInLightAndDarkAppearance() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["MACAROK_SNAPSHOT_DIRECTORY"], !outputPath.isEmpty else {
            throw XCTSkip("Set MACAROK_SNAPSHOT_DIRECTORY to opt in to offscreen native component rendering.")
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let demo = packageRoot.appendingPathComponent(".build/demo-library", isDirectory: true)
        let marker = demo.appendingPathComponent(".macarok-demo.json")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            XCTFail("Generate synthetic fixtures first: python3 scripts/create-demo-library.py .build/demo-library")
            return
        }
        let manifest = try JSONDecoder().decode(DemoManifest.self, from: Data(contentsOf: marker))
        XCTAssertEqual(manifest.name, "Macarok Demo")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokNativeRender-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try LibraryStore(url: temporary.appendingPathComponent("render.sqlite"))
        let source = SourceRecord(id: "native-render-demo", kind: .local, name: "Macarok Demo", location: demo.absoluteString)
        let scanner = LibraryScanner(artworkCacheURL: temporary.appendingPathComponent("Artwork", isDirectory: true))
        let scan = try await scanner.scan(source: source, metadataReader: { try TagLibMetadataService.read(url: $0) })
        XCTAssertTrue(scan.isComplete)
        XCTAssertEqual(scan.tracks.count, manifest.expectedTracks)
        XCTAssertTrue(scan.warnings.isEmpty, scan.warnings.joined(separator: "\n"))
        try store.saveSource(source)
        try store.upsertTracks(scan.tracks)

        // Seed only the isolated index so Home has visible listening history.
        for (index, track) in scan.tracks.prefix(5).enumerated() {
            for _ in 0..<(index + 1) {
                try store.recordPlay(trackID: track.id, at: Date().addingTimeInterval(-Double(index + 1) * 3_600))
            }
        }
        var preferences = AppPreferences()
        preferences.volume = 0
        let model = AppModel(store: store, preferences: preferences, registerSystemControls: false)
        await model.start()
        let emptyStore = try LibraryStore(url: temporary.appendingPathComponent("empty.sqlite"))
        try emptyStore.saveSource(source)
        let emptyModel = AppModel(store: emptyStore, preferences: preferences, registerSystemControls: false)
        await emptyModel.start()
        model.sourceID = source.id
        let cueAlbum = try XCTUnwrap(model.albums.first { $0.tracks.contains(where: \.isCUETrack) })
        XCTAssertEqual(cueAlbum.tracks.count, 3)
        let cueTrack = try XCTUnwrap(cueAlbum.tracks.dropFirst().first)
        model.add(Array(model.tracks.filter { !$0.isCUETrack }.prefix(5)) + cueAlbum.tracks)
        model.currentQueueID = model.queue.first?.id
        model.settings.repeatMode = .playlist

        // NSApplication supplies the AppKit environment. No application activation or window ordering occurs.
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            emptyModel.isRefreshing = true
            emptyModel.refreshProgress = "Reading album 14 of 200…"
            try await render(ContextPane(model: emptyModel), size: NSSize(width: 370, height: 680), scheme: scheme,
                             destination: output.appendingPathComponent("empty-home-loading-\(suffix).png"))
            emptyModel.isRefreshing = false
            try await render(ContextPane(model: emptyModel), size: NSSize(width: 590, height: 860), scheme: scheme,
                             destination: output.appendingPathComponent("empty-home-idle-\(suffix).png"))
            model.settings.appearance = scheme == .light ? .light : .dark
            model.libraryView = .home
            model.contextPage = .home
            try await render(MainWindow(model: model), size: NSSize(width: 1380, height: 860), scheme: scheme,
                             destination: output.appendingPathComponent("home-\(suffix).png"))

            model.libraryView = .albums
            model.inspect(cueAlbum)
            try await render(MainWindow(model: model), size: NSSize(width: 1380, height: 860), scheme: scheme,
                             destination: output.appendingPathComponent("cue-album-\(suffix).png"))

            model.libraryView = .tags
            model.inspect(cueTrack)
            model.contextTab = "Tags"
            try await render(MainWindow(model: model), size: NSSize(width: 1380, height: 860), scheme: scheme,
                             destination: output.appendingPathComponent("track-tags-\(suffix).png"))

            try await render(SettingsView(model: model), size: NSSize(width: 650, height: 555), scheme: scheme,
                             destination: output.appendingPathComponent("settings-\(suffix).png"))
            try await render(MetadataEditor(model: model, track: cueTrack), size: NSSize(width: 680, height: 720), scheme: scheme,
                             destination: output.appendingPathComponent("metadata-editor-\(suffix).png"))
        }
        XCTAssertEqual(model.player.state, .stopped)
    }

    private func render<Content: View>(_ content: Content, size: NSSize, scheme: ColorScheme, destination: URL) async throws {
        let appearance = try XCTUnwrap(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
        let hosting = NSHostingView(rootView: content
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: "en_US")))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = appearance
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        window.setContentSize(size)
        defer {
            window.contentView = nil
            window.close()
        }
        XCTAssertFalse(window.isVisible)
        // Allow SwiftUI layout and local artwork tasks to settle without sending events or entering a modal loop.
        for _ in 0..<12 {
            hosting.layoutSubtreeIfNeeded()
            await Task.yield()
            try await Task.sleep(for: .milliseconds(25))
        }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 4_096, "A component render should contain visible controls and text.")
        XCTAssertGreaterThan(sampledColorCount(bitmap), 2, "The native component rendered a blank bitmap.")
        try data.write(to: destination, options: .atomic)
        XCTAssertFalse(window.isVisible)
    }

    private func sampledColorCount(_ bitmap: NSBitmapImageRep) -> Int {
        var colors = Set<String>()
        for row in 0..<20 {
            for column in 0..<20 {
                let x = min(bitmap.pixelsWide - 1, column * max(1, bitmap.pixelsWide - 1) / 19)
                let y = min(bitmap.pixelsHigh - 1, row * max(1, bitmap.pixelsHigh - 1) / 19)
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255)),\(Int(color.alphaComponent * 255))")
                }
            }
        }
        return colors.count
    }

    private struct DemoManifest: Decodable {
        var name: String
        var expectedTracks: Int
        enum CodingKeys: String, CodingKey { case name; case expectedTracks = "expected_tracks" }
    }
}
