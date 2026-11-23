import AppKit
import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

@MainActor
final class MenuBarControllerTests: XCTestCase {
    func testDisabledDefaultAndPreferenceTogglesDoNotCreateDuplicatePresentations() async throws {
        _ = NSApplication.shared
        let preferences = AppPreferences()
        XCTAssertFalse(preferences.showMenuBar)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        legacy.removeValue(forKey: "showMenuBar")
        let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(restored.showMenuBar)
        let model = AppModel(preferences: preferences, registerSystemControls: false)
        let host = TestMenuBarHost()
        let controller = MenuBarController(model: model, host: host)
        defer { controller.stop() }
        model.queue = [QueueItem(track: TrackRecord(id: "track", sourceID: "source", title: "Queued song", artist: "Artist"))]
        model.currentQueueID = model.queue[0].id
        await settle()
        XCTAssertEqual(host.installations, 0)
        XCTAssertFalse(host.visible)
        model.settings.showMenuBar = true
        try await eventually { host.visible }
        let player = try XCTUnwrap(host.player)
        XCTAssertEqual(host.installations, 1)
        XCTAssertEqual(player.state.title, "Queued song")
        let initialUpdates = host.updates
        model.settings.showMenuBar = true
        await settle()
        XCTAssertEqual(host.updates, initialUpdates)
        model.artworkRevision += 1
        try await eventually { player.state.artworkRevision == model.artworkRevision }
        XCTAssertTrue(host.player === player)
        XCTAssertEqual(host.installations, 1, "Artwork updates must reuse the installed status item and popover presentation.")
        model.settings.showMenuBar = false
        try await eventually { !host.visible }
        controller.stop()
        model.settings.showMenuBar = true
        await settle()
        XCTAssertFalse(host.visible, "Queued Observation callbacks must not resurrect a stopped status item.")
        XCTAssertFalse(player.state.enabled)
    }

    func testTrackAndRadioMetadataUpdateAndActionsResolveTheCurrentEntry() async throws {
        _ = NSApplication.shared
        var preferences = AppPreferences(); preferences.showMenuBar = true
        let model = AppModel(preferences: preferences, registerSystemControls: false)
        model.sources = [SourceRecord(id: "music", kind: .openSubsonic, name: "Music", location: "https://music.invalid"),
                         SourceRecord(id: "radio", kind: .radio, name: "Radio", location: "")]
        model.queue = [
            QueueItem(track: TrackRecord(id: "first", sourceID: "music", title: "First song", artist: "First artist")),
            QueueItem(track: TrackRecord(id: "second", sourceID: "music", title: "Second song", artist: "Second artist")),
            QueueItem(track: TrackRecord(id: "station", sourceID: "radio", title: "Synthetic Station", artist: "Internet Radio"))
        ]
        model.currentQueueID = model.queue[0].id
        let host = TestMenuBarHost()
        let controller = MenuBarController(model: model, host: host)
        defer { controller.stop() }
        let player = try XCTUnwrap(host.player)
        XCTAssertEqual(player.state.title, "First song")
        XCTAssertEqual(player.state.artist, "First artist")
        model.currentQueueID = model.queue[1].id
        try await eventually { player.state.title == "Second song" }
        model.queue[1].track.title = "Corrected song title"
        try await eventually { player.state.title == "Corrected song title" }
        XCTAssertTrue(host.player === player)
        XCTAssertEqual(host.installations, 1)
        model.currentQueueID = model.queue[2].id
        model.player.pauseLive()
        model.radioBroadcastTitle = "Artist — Current broadcast"
        try await eventually { player.state.title == "Synthetic Station" && player.state.artist == "Artist — Current broadcast" }
        XCTAssertTrue(player.state.isRadio)
        XCTAssertEqual(player.state.playPauseTitle, "Play")
        model.radioDisconnected = true
        try await eventually { player.state.playPauseTitle == "Reconnect" }
        XCTAssertEqual(player.state.playPauseSymbol, "arrow.clockwise")
        let current = model.currentQueueID
        player.perform(.next)
        XCTAssertEqual(model.currentQueueID, current, "An open mini player must advance from the actual final entry, not a captured older track.")
        XCTAssertEqual(model.status, "Playback finished.")
        model.settings.showMenuBar = false
        try await eventually { !host.visible }
        model.status = "Disabled mini player stayed passive"
        player.perform(.next)
        XCTAssertEqual(model.status, "Disabled mini player stayed passive")
    }

    func testPlayPauseUsesExistingActionsWithoutObservingThePlaybackClock() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokMenuBarPlayback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("menu.wav")
        try wave(seconds: 10).write(to: url)
        var preferences = AppPreferences(); preferences.showMenuBar = true; preferences.volume = 0
        let model = AppModel(preferences: preferences, registerSystemControls: false)
        let source = SourceRecord(id: "menu-local", kind: .local, name: "Synthetic", location: directory.absoluteString)
        model.sources = [source]
        model.queue = [QueueItem(track: TrackRecord(id: "menu-local-track", sourceID: source.id, title: "Menu playback", artist: "Synthetic Artist", duration: 10, fileURL: url.absoluteString))]
        model.player.volume = 0
        let host = TestMenuBarHost()
        let controller = MenuBarController(model: model, host: host)
        defer { controller.stop(); model.stopPlayback(clearCurrent: true) }
        let player = try XCTUnwrap(host.player)
        player.perform(.playPause)
        try await eventually { model.player.state == .playing && model.player.position > 0.2 && player.state.playPauseTitle == "Pause" }
        let initialPosition = model.player.position, initialUpdates = host.updates
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertGreaterThan(model.player.position, initialPosition + 0.2)
        XCTAssertEqual(host.updates, initialUpdates, "Five-Hz clock publications must not rebuild the status item or artwork presentation.")
        XCTAssertEqual(host.installations, 1)
        player.perform(.playPause)
        try await eventually { model.player.state == .paused && player.state.playPauseTitle == "Play" }
        XCTAssertEqual(model.currentQueueID, model.queue[0].id)
    }

    func testOpenMainWindowAndAppearanceUseExistingModelBehavior() async throws {
        _ = NSApplication.shared
        var preferences = AppPreferences(); preferences.showMenuBar = true
        let model = AppModel(preferences: preferences, registerSystemControls: false)
        var openedWindows = 0
        model.openMainWindow = { openedWindows += 1 }
        let host = TestMenuBarHost()
        let controller = MenuBarController(model: model, host: host)
        defer { controller.stop() }
        let player = try XCTUnwrap(host.player)
        player.perform(.showWindow)
        XCTAssertEqual(openedWindows, 1)
        for appearance in [Appearance.light, .dark, .system] {
            model.settings.appearance = appearance
            try await eventually { player.state.appearance == appearance }
        }
        controller.stop()
        player.perform(.showWindow)
        XCTAssertEqual(openedWindows, 1)
    }

    func testShowWindowRestoresMinimizedWindowInsteadOfOpeningAnother() async throws {
        _ = NSApplication.shared
        let model = AppModel(preferences: AppPreferences(), registerSystemControls: false)
        var openedWindows = 0
        model.openMainWindow = { openedWindows += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        model.mainPlayerWindow = window
        window.orderFront(nil)
        window.miniaturize(nil)
        try await eventually { window.isMiniaturized && !window.isVisible }
        model.showMainWindow()
        try await eventually { !window.isMiniaturized && window.isVisible }
        XCTAssertEqual(openedWindows, 0, "A minimized main window must be restored, not duplicated.")
    }

    func testDockReopenOpensClosedMainWindowThroughModel() {
        _ = NSApplication.shared
        let model = AppModel(preferences: AppPreferences(), registerSystemControls: false)
        var openedWindows = 0
        model.openMainWindow = { openedWindows += 1 }
        let delegate = ApplicationDelegate()
        delegate.model = model
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertEqual(openedWindows, 1)
    }

    func testRetainedPresentationDoesNotRetainControllerOrAppModel() async throws {
        _ = NSApplication.shared
        var preferences = AppPreferences(); preferences.showMenuBar = true
        var model: AppModel? = AppModel(preferences: preferences, registerSystemControls: false)
        weak var weakModel = model
        let host = TestMenuBarHost()
        var controller: MenuBarController? = MenuBarController(model: try XCTUnwrap(model), host: host)
        weak var weakController = controller
        let player = try XCTUnwrap(host.player)
        XCTAssertTrue(host.visible)
        controller = nil
        model = nil
        try await eventually { weakController == nil && weakModel == nil && !host.visible }
        player.perform(.playPause)
        player.perform(.showWindow)
        await player.prepareArtwork?()
        XCTAssertFalse(host.visible)
        XCTAssertEqual(host.installations, 1)
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(40)) }
    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate())
    }

    private func wave(seconds: Int) -> Data {
        let rate = 16_000, count = seconds * rate * 2
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + count)); data.append(Data("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(rate)); append(UInt32(rate * 2))
        append(UInt16(2)); append(UInt16(16)); data.append(Data("data".utf8)); append(UInt32(count))
        data.append(Data(repeating: 0, count: count)); return data
    }
}

@MainActor
private final class TestMenuBarHost: MenuBarHosting {
    private(set) var player: MenuBarPlayerPresentation?
    private(set) var visible = false
    private(set) var installations = 0
    private(set) var updates = 0
    func show(player: MenuBarPlayerPresentation) {
        if !visible { installations += 1 }
        self.player = player; visible = true; updates += 1
    }
    func hide() { visible = false }

    @MainActor
    func testMenuBarIconIsAnEighteenPointTemplateWithEveryScale() {
        let image = MenuBarIcon.image
        XCTAssertTrue(image.isTemplate, "The menu bar draws a template in its own color and highlight.")
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(image.representations.map(\.pixelsWide).sorted(), [18, 36, 54], "Every embedded scale decodes.")
    }
}
