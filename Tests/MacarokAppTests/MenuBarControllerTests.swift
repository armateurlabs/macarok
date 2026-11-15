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
        XCTAssertEqual(host.installations, 1)
        XCTAssertEqual(try item("menuBarTrackTitle", in: host).title, "Queued song")
        let initialUpdates = host.updates
        model.settings.showMenuBar = true
        model.artworkRevision += 1
        await settle()
        XCTAssertEqual(host.updates, initialUpdates)
        XCTAssertEqual(host.installations, 1)
        model.settings.showMenuBar = false
        try await eventually { !host.visible }
        controller.stop()
        model.settings.showMenuBar = true
        await settle()
        XCTAssertFalse(host.visible, "Queued Observation callbacks must not resurrect a stopped status item.")
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
        let originalMenu = try XCTUnwrap(host.menu)
        XCTAssertEqual(try item("menuBarTrackTitle", in: host).title, "First song")
        XCTAssertEqual(try item("menuBarTrackArtist", in: host).title, "First artist")
        XCTAssertFalse(try item("menuBarTrackTitle", in: host).isEnabled)
        XCTAssertFalse(try item("menuBarTrackArtist", in: host).isEnabled)
        XCTAssertNotNil(try item("menuBarShowWindow", in: host).action)
        XCTAssertNotNil(try item("menuBarQuit", in: host).action)
        model.currentQueueID = model.queue[1].id
        try await eventually { host.title("menuBarTrackTitle") == "Second song" }
        model.queue[1].track.title = "Corrected song title"
        try await eventually { host.title("menuBarTrackTitle") == "Corrected song title" }
        XCTAssertTrue(host.menu === originalMenu)
        XCTAssertEqual(host.installations, 1)
        model.currentQueueID = model.queue[2].id
        model.player.pauseLive()
        model.radioBroadcastTitle = "Artist — Current broadcast"
        try await eventually { host.title("menuBarTrackTitle") == "Synthetic Station" && host.title("menuBarTrackArtist") == "Artist — Current broadcast" }
        XCTAssertEqual(try item("menuBarPlayPause", in: host).title, "Play")
        model.radioDisconnected = true
        try await eventually { host.title("menuBarPlayPause") == "Reconnect" }
        let current = model.currentQueueID
        let next = try XCTUnwrap(originalMenu.items.firstIndex { $0.identifier?.rawValue == "menuBarNext" })
        originalMenu.performActionForItem(at: next)
        XCTAssertEqual(model.currentQueueID, current, "An already-open menu must advance from the actual final entry, not a captured older track.")
        XCTAssertEqual(model.status, "Playback finished.")
        model.settings.showMenuBar = false
        try await eventually { !host.visible }
        model.status = "Disabled menu stayed passive"
        originalMenu.performActionForItem(at: next)
        XCTAssertEqual(model.status, "Disabled menu stayed passive")
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
        try perform("menuBarPlayPause", host: host)
        try await eventually { model.player.state == .playing && model.player.position > 0.2 && host.title("menuBarPlayPause") == "Pause" }
        let initialPosition = model.player.position, initialUpdates = host.updates
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertGreaterThan(model.player.position, initialPosition + 0.2)
        XCTAssertEqual(host.updates, initialUpdates, "Five-Hz clock publications must not rebuild the status menu.")
        XCTAssertEqual(host.installations, 1)
        try perform("menuBarPlayPause", host: host)
        try await eventually { model.player.state == .paused && host.title("menuBarPlayPause") == "Play" }
        XCTAssertEqual(model.currentQueueID, model.queue[0].id)
    }

    func testDeinitializingControllerRemovesPresentationAndLeavesNoLiveObservation() async throws {
        _ = NSApplication.shared
        var preferences = AppPreferences(); preferences.showMenuBar = true
        let model = AppModel(preferences: preferences, registerSystemControls: false)
        let host = TestMenuBarHost()
        var controller: MenuBarController? = MenuBarController(model: model, host: host)
        weak var weakController = controller
        XCTAssertTrue(host.visible)
        controller = nil
        try await eventually { weakController == nil && !host.visible }
        model.settings.showMenuBar = false
        model.settings.showMenuBar = true
        await settle()
        XCTAssertFalse(host.visible)
        XCTAssertEqual(host.installations, 1)
    }

    private func item(_ identifier: String, in host: TestMenuBarHost) throws -> NSMenuItem {
        try XCTUnwrap(host.menu?.items.first { $0.identifier?.rawValue == identifier })
    }

    private func perform(_ identifier: String, host: TestMenuBarHost) throws {
        let menu = try XCTUnwrap(host.menu)
        let index = try XCTUnwrap(menu.items.firstIndex { $0.identifier?.rawValue == identifier })
        menu.performActionForItem(at: index)
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
    private(set) var menu: NSMenu?
    private(set) var visible = false
    private(set) var installations = 0
    private(set) var updates = 0
    func show(menu: NSMenu) {
        if !visible { installations += 1 }
        self.menu = menu; visible = true; updates += 1
    }
    func hide() { visible = false }
    func title(_ identifier: String) -> String? { menu?.items.first { $0.identifier?.rawValue == identifier }?.title }
}
