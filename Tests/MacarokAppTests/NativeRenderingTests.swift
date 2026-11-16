import AppKit
import Foundation
import MacarokCore
import MacarokMetadata
import SwiftUI
import XCTest
@testable import MacarokApp

/// Native geometry checks and opt-in software renders, without screen capture or UI interaction.
@MainActor
final class NativeRenderingTests: XCTestCase {
    func testCenterHeadersStayCenteredAcrossNavigationAndAppearances() async throws {
        _ = NSApplication.shared
        let model = AppModel(preferences: AppPreferences(), registerSystemControls: false)
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(370), 590, 900] {
                let hosting = NSHostingView(rootView: CenterPanelHeader(model: model)
                    .frame(width: width, height: 86)
                    .environment(\.colorScheme, scheme))
                hosting.sizingOptions = []
                hosting.frame = NSRect(x: 0, y: 0, width: width, height: 86)
                let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                window.contentView = hosting
                defer { window.contentView = nil; window.close() }
                var rowCenters: [CGFloat]?
                for page in CenterPage.allCases {
                    model.centerPage = page
                    let count = page == .home ? HomeFilter.allCases.count : ContextMode.allCases.count
                    for index in 0..<count {
                        if page == .home { model.homeFilter = HomeFilter.allCases[index] }
                        else { model.contextMode = ContextMode.allCases[index] }
                        for _ in 0..<6 { hosting.layoutSubtreeIfNeeded(); await Task.yield(); try await Task.sleep(for: .milliseconds(5)) }
                        let controls = segmentedControls(in: hosting)
                        XCTAssertEqual(controls.count, 2, "Every page and empty state must keep both header selectors.")
                        let frames = controls.map { $0.convert($0.bounds, to: hosting) }.sorted { $0.midY < $1.midY }
                        guard frames.count == 2 else { continue }
                        for frame in frames {
                            XCTAssertEqual(frame.midX, width / 2, accuracy: 1, "Selectors must remain centered in the context panel.")
                            XCTAssertGreaterThanOrEqual(frame.minX, 0)
                            XCTAssertLessThanOrEqual(frame.maxX, width + 1)
                            XCTAssertLessThanOrEqual(frame.height, 42)
                        }
                        XCTAssertEqual(frames[1].midY - frames[0].midY, 43, accuracy: 1, "Both rows reserve 42 points plus the full-width divider.")
                        if let rowCenters {
                            for (frame, expected) in zip(frames, rowCenters) { XCTAssertEqual(frame.midY, expected, accuracy: 1) }
                        } else { rowCenters = frames.map(\.midY) }
                        XCTAssertFalse(window.isVisible)
                    }
                }
            }
        }
    }

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
        try store.saveRadioStation(RadioStationRecord(id: "native-render-radio", name: "Macarok Demo Radio", streamURL: "https://radio.invalid/live.mp3",
                                                     country: "France", language: "English", codec: "MP3", bitrate: 192, isFavorite: true))
        try store.saveSource(SourceRecord(id: "native-render-podcast", kind: .podcasts, name: "Macarok Demo Podcast",
                                          location: "https://podcast.invalid/feed.xml"))

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
        model.scrobbling = ScrobblingController(store: store, credentials: NativePreviewLastFMKeys())
        let emptyStore = try LibraryStore(url: temporary.appendingPathComponent("empty.sqlite"))
        try emptyStore.saveSource(source)
        let emptyModel = AppModel(store: emptyStore, preferences: preferences, registerSystemControls: false)
        await emptyModel.start()
        model.sourceID = source.id
        await model.waitForLibraryLoad()
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
            emptyModel.centerPage = .home
            emptyModel.contextMode = .context
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
            model.homeFilter = .all
            try await render(MainWindow(model: model), size: NSSize(width: 1380, height: 860), scheme: scheme,
                             destination: output.appendingPathComponent("home-\(suffix).png"))
            model.isRefreshing = true
            model.refreshProgress = "Connecting to Macarok Demo and waiting for the music server…"
            try await render(LibraryPane(model: model), size: NSSize(width: 245, height: 680), scheme: scheme,
                             destination: output.appendingPathComponent("library-refreshing-\(suffix).png"))
            model.isStoppingRefresh = true
            try await render(LibraryPane(model: model), size: NSSize(width: 245, height: 680), scheme: scheme,
                             destination: output.appendingPathComponent("library-stopping-\(suffix).png"))
            model.isRefreshing = false; model.isStoppingRefresh = false; model.refreshProgress = ""
            for filter in [HomeFilter.recentlyAdded, .recentlyPlayed, .mostPlayed] {
                model.homeFilter = filter
                try await render(ContextPane(model: model), size: NSSize(width: 590, height: 860), scheme: scheme,
                                 destination: output.appendingPathComponent("home-\(filter.rawValue)-\(suffix).png"))
            }
            model.homeFilter = .all

            model.libraryView = .albums
            model.inspect(cueAlbum)
            try await render(MainWindow(model: model), size: NSSize(width: 1380, height: 860), scheme: scheme,
                             destination: output.appendingPathComponent("cue-album-\(suffix).png"))

            model.libraryView = .tags
            model.inspect(cueTrack)
            model.contextTab = "Tags"
            try await render(MainWindow(model: model), size: NSSize(width: 1380, height: 860), scheme: scheme,
                             destination: output.appendingPathComponent("track-tags-\(suffix).png"))
            model.centerPage = .playing
            try await render(ContextPane(model: model), size: NSSize(width: 370, height: 680), scheme: scheme,
                             destination: output.appendingPathComponent("playing-tags-narrow-\(suffix).png"))

            let editingQueueID = try XCTUnwrap(model.currentQueueID)
            let editingTrack = try XCTUnwrap(model.currentTrack)
            model.beginMetadataEditing(editingTrack)
            let session = try XCTUnwrap(model.metadataEditingSession)
            session.draft.title = editingTrack.title + " — Draft"
            for width in [CGFloat(370), 590] {
                try await render(ContextPane(model: model), size: NSSize(width: width, height: 860), scheme: scheme,
                                 destination: output.appendingPathComponent("inline-metadata-\(Int(width))-\(suffix).png"))
            }
            let nextEntry = try XCTUnwrap(model.queue.first { $0.id != editingQueueID })
            model.currentQueueID = nextEntry.id
            XCTAssertEqual(model.playingContextTrack?.id, editingTrack.id)
            XCTAssertEqual(model.metadataEditingSession?.id, session.id)
            XCTAssertEqual(session.draft.title, editingTrack.title + " — Draft")
            XCTAssertEqual(model.contextMode, .editMetadata)
            try await render(ContextPane(model: model), size: NSSize(width: 590, height: 860), scheme: scheme,
                             destination: output.appendingPathComponent("inline-metadata-pinned-\(suffix).png"))
            model.finishMetadataEditing()
            XCTAssertEqual(model.playingContextTrack?.id, nextEntry.track.id)
            XCTAssertEqual(model.contextTab, "Tags")
            model.currentQueueID = editingQueueID

            try await render(SettingsView(model: model), size: NSSize(width: 650, height: 555), scheme: scheme,
                             destination: output.appendingPathComponent("settings-\(suffix).png"))
            for (tab, name) in [(SettingsTab.playback, "playback"), (.shortcuts, "shortcuts")] {
                try await render(SettingsView(model: model, initialTab: tab), size: NSSize(width: 650, height: 555), scheme: scheme,
                                 destination: output.appendingPathComponent("settings-\(name)-\(suffix).png"))
            }
            try await render(SettingsView(model: model, initialTab: .scrobbling), size: NSSize(width: 650, height: 555), scheme: scheme,
                             destination: output.appendingPathComponent("settings-scrobbling-\(suffix).png"))
            try await render(MetadataEditor(model: model, track: cueTrack), size: NSSize(width: 680, height: 720), scheme: scheme,
                             destination: output.appendingPathComponent("metadata-editor-\(suffix).png"))
            try await render(AddSourceSheet(model: model, initialKind: .bandcamp), size: NSSize(width: 790, height: 650), scheme: scheme,
                             destination: output.appendingPathComponent("source-catalog-\(suffix).png"))
            try await render(PodcastDiscoverySheet { _ in }, size: NSSize(width: 650, height: 590), scheme: scheme,
                             destination: output.appendingPathComponent("podcast-discovery-\(suffix).png"))
            for repeatMode in RepeatMode.allCases {
                model.settings.repeatMode = repeatMode
                try await render(QueuePane(model: model, player: model.player), size: NSSize(width: 270, height: 680), scheme: scheme,
                                 destination: output.appendingPathComponent("playlist-\(repeatMode.rawValue)-\(suffix).png"))
            }
            model.settings.repeatMode = .none
            model.settings.playlistAlbumGroups = true
            try await render(QueuePane(model: model, player: model.player), size: NSSize(width: 330, height: 680), scheme: scheme,
                             destination: output.appendingPathComponent("playlist-album-groups-\(suffix).png"))
            model.settings.playlistAlbumGroups = false
            model.libraryScope = .source(RadioLibrary.sourceID)
            await model.waitForLibraryLoad()
            model.contextPage = .home
            try await render(MainWindow(model: model), size: NSSize(width: 1050, height: 680), scheme: scheme,
                             destination: output.appendingPathComponent("radio-library-\(suffix).png"))
            model.libraryScope = .source(source.id)
            await model.waitForLibraryLoad()
        }
        let duplicateSource = SourceRecord(id: "native-render-secondary", kind: .openSubsonic, name: "Second Library", location: "https://music.invalid")
        try store.saveSource(duplicateSource)
        let original = try XCTUnwrap(scan.tracks.first { !$0.isCUETrack })
        var duplicate = original
        duplicate.id = "native-render-duplicate-track"
        duplicate.sourceID = duplicateSource.id
        duplicate.fileURL = nil
        duplicate.remoteID = "native-render-remote"
        // Keep the same raw album identifier to exercise source-qualified presentation identity.
        var longAlbum = original
        longAlbum.id = "native-render-long-title-track"
        longAlbum.albumID = "native-render-long-title-album"
        longAlbum.album = "A Longer Album Title That Occupies Two Lines"
        try store.upsertTracks([duplicate, longAlbum])
        for track in [duplicate, longAlbum] { try store.recordPlay(trackID: track.id, at: Date()) }
        model.sources = try store.sources()
        model.libraryScope = .all
        await model.waitForLibraryLoad()
        XCTAssertEqual(Set(model.tracks.map(\.sourceID)), [source.id, duplicateSource.id])
        XCTAssertEqual(Set(model.albums.map(\.presentationID)).count, model.albums.count)
        XCTAssertEqual(model.albums.filter { $0.id == original.albumID }.count, 2)
        let current = try XCTUnwrap(model.currentTrack)
        let document = LRCParser.parse("[00:00.00]A quiet road beneath the stars\n[00:03.00]A second line for our synthetic song\n[00:06.00]The music carries on\n", source: .manual)
        try store.saveLyrics(.from(document), for: LyricsLookupQuery(track: current), manual: true)

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            model.contextMode = .context
            model.libraryView = .home
            model.contextPage = .home
            try await render(MainWindow(model: model), size: NSSize(width: 1050, height: 860), scheme: scheme,
                             destination: output.appendingPathComponent("all-home-narrow-\(suffix).png"))
            try await render(MainWindow(model: model), size: NSSize(width: 1600, height: 1000), scheme: scheme,
                             destination: output.appendingPathComponent("all-home-wide-\(suffix).png"))
            model.inspectArtist(original.albumArtist)
            try await render(MainWindow(model: model), size: NSSize(width: 1380, height: 860), scheme: scheme,
                             destination: output.appendingPathComponent("artist-albums-\(suffix).png"))
            model.centerPage = .playing
            model.contextMode = .lyrics
            try await render(MainWindow(model: model), size: NSSize(width: 1380, height: 860), scheme: scheme,
                             destination: output.appendingPathComponent("lyrics-synced-\(suffix).png"))
            emptyModel.centerPage = .playing
            emptyModel.contextMode = .lyrics
            try await render(ContextPane(model: emptyModel), size: NSSize(width: 370, height: 680), scheme: scheme,
                             destination: output.appendingPathComponent("lyrics-empty-\(suffix).png"))
            try await render(SettingsView(model: model, initialTab: .sources), size: NSSize(width: 650, height: 555), scheme: scheme,
                             destination: output.appendingPathComponent("settings-sources-\(suffix).png"))
        }
        XCTAssertEqual(model.player.state, .stopped)
    }

    private func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
        if let control = view as? NSSegmentedControl { return [control] }
        return view.subviews.flatMap { segmentedControls(in: $0) }
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
        for row in 0..<60 {
            for column in 0..<60 {
                let x = min(bitmap.pixelsWide - 1, column * max(1, bitmap.pixelsWide - 1) / 59)
                let y = min(bitmap.pixelsHigh - 1, row * max(1, bitmap.pixelsHigh - 1) / 59)
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

private struct NativePreviewLastFMKeys: LastFMCredentialStorage {
    func load() throws -> LastFMCredentialRecord? {
        LastFMCredentialRecord(application: LastFMAppCredentials(apiKey: "preview-api-key", sharedSecret: "preview-secret"))
    }
    func save(_ credentials: LastFMCredentialRecord) throws { }
    func delete() throws { }
}
