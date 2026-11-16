import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import MacarokApp

@MainActor
final class PlayingAutoSwitchPreferenceTests: XCTestCase {
    func testLegacyPreferencesDefaultToManualTrackStartWithoutResettingOtherChoices() throws {
        let data = Data(#"{"appearance":"dark","showMenuBar":true,"repeatMode":"track","doubleClickPlays":true,"customBuffer":true,"bufferSeconds":42,"volume":0.3,"localShortcuts":{"playPause":"AQID","showCurrentTrack":"BAU="}}"#.utf8)

        let restored = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertEqual(AppPreferences().playingAutoSwitchMode, .manualTrackStart)
        XCTAssertEqual(restored.playingAutoSwitchMode, .manualTrackStart)
        XCTAssertEqual(restored.trackDoubleClickAction, .playNow)
        assertOtherPreferences(restored)
    }

    func testEveryModeRoundTripsAlongsideExistingPreferences() throws {
        for mode in PlayingAutoSwitchMode.allCases {
            var preferences = configuredPreferences()
            preferences.playingAutoSwitchMode = mode

            let data = try JSONEncoder().encode(preferences)
            let restored = try JSONDecoder().decode(AppPreferences.self, from: data)

            XCTAssertEqual(restored.playingAutoSwitchMode, mode)
            XCTAssertEqual(restored.trackDoubleClickAction, .afterCurrent)
            assertOtherPreferences(restored)
        }
    }

    func testUnknownModeFallsBackWithoutDiscardingSavedPreferences() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuredPreferences())) as? [String: Any])
        object["playingAutoSwitchMode"] = "futurePlaybackPolicy"

        let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertEqual(restored.playingAutoSwitchMode, .manualTrackStart)
        XCTAssertEqual(restored.trackDoubleClickAction, .afterCurrent)
        assertOtherPreferences(restored)
    }

    func testNativeGeneralPickerFitsAllOptionsInLightAndDarkSettings() async throws {
        _ = NSApplication.shared
        let model = AppModel(preferences: AppPreferences(), registerSystemControls: false)
        let titles = ["Every manually started track", "First playback after app launch", "First playback after Stop or playlist end"]
        XCTAssertEqual(PlayingAutoSwitchMode.allCases.map(\.title), titles)

        for scheme in [ColorScheme.light, .dark] {
            let appearance = try XCTUnwrap(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
            let size = NSSize(width: 650, height: 555)
            let hosting = NSHostingView(rootView: SettingsView(model: model, initialTab: .general)
                .frame(width: size.width, height: size.height)
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

            for mode in PlayingAutoSwitchMode.allCases {
                model.settings.playingAutoSwitchMode = mode
                for _ in 0..<12 {
                    hosting.layoutSubtreeIfNeeded()
                    await Task.yield()
                    try await Task.sleep(for: .milliseconds(10))
                }
                let nativePopups = popups(in: hosting)
                guard let picker = nativePopups.first(where: { $0.itemTitles == titles }) else {
                    let snapshot = try capture(hosting, scheme: scheme, failure: true)
                    let details = nativePopups.map { "\(type(of: $0)): \($0.itemTitles), frame=\($0.convert($0.bounds, to: hosting))" }
                    let classes = Dictionary(grouping: descendants(hosting), by: { String(describing: type(of: $0)) })
                        .mapValues(\.count).sorted { $0.key < $1.key }
                    XCTFail("General must expose all three modes in a native menu picker. Popups: \(details). Native views: \(classes). Snapshot: \(snapshot?.path ?? "unavailable").")
                    return
                }
                XCTAssertEqual(picker.accessibilityIdentifier(), "playingAutoSwitchModePicker")
                XCTAssertEqual(picker.accessibilityLabel(), "Show Playing automatically")
                XCTAssertEqual(picker.title, mode.title)
                let frame = picker.convert(picker.bounds, to: hosting)
                XCTAssertGreaterThan(frame.width, 200)
                XCTAssertGreaterThan(frame.height, 15)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertGreaterThanOrEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxX, size.width)
                XCTAssertLessThanOrEqual(frame.maxY, size.height)
                if let cell = picker.cell {
                    XCTAssertLessThanOrEqual(cell.cellSize.width, frame.width + 1,
                                             "The longest selected option must fit without truncation.")
                }
                let next = PlayingAutoSwitchMode.allCases[(picker.indexOfSelectedItem + 1) % titles.count]
                let action = try XCTUnwrap(picker.action)
                picker.selectItem(withTitle: next.title)
                picker.sendAction(action, to: picker.target)
                XCTAssertEqual(model.settings.playingAutoSwitchMode, next)
                picker.selectItem(withTitle: mode.title)
                picker.sendAction(action, to: picker.target)
                XCTAssertEqual(model.settings.playingAutoSwitchMode, mode)
                XCTAssertFalse(window.isVisible)
            }
            _ = try capture(hosting, scheme: scheme)
        }
        XCTAssertEqual(model.player.state, .stopped)
        XCTAssertTrue(model.queue.isEmpty)
    }

    private func configuredPreferences() -> AppPreferences {
        var preferences = AppPreferences()
        preferences.appearance = .dark
        preferences.showMenuBar = true
        preferences.repeatMode = .track
        preferences.trackDoubleClickAction = .afterCurrent
        preferences.customBuffer = true
        preferences.bufferSeconds = 42
        preferences.volume = 0.3
        preferences.localShortcuts = ["playPause": Data([1, 2, 3]), "showCurrentTrack": Data([4, 5])]
        return preferences
    }

    private func assertOtherPreferences(_ preferences: AppPreferences, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(preferences.appearance, .dark, file: file, line: line)
        XCTAssertTrue(preferences.showMenuBar, file: file, line: line)
        XCTAssertEqual(preferences.repeatMode, .track, file: file, line: line)
        XCTAssertTrue(preferences.customBuffer, file: file, line: line)
        XCTAssertEqual(preferences.bufferSeconds, 42, file: file, line: line)
        XCTAssertEqual(preferences.buffer, 42, file: file, line: line)
        XCTAssertEqual(preferences.volume, 0.3, file: file, line: line)
        XCTAssertEqual(preferences.localShortcuts, ["playPause": Data([1, 2, 3]), "showCurrentTrack": Data([4, 5])], file: file, line: line)
    }

    private func popups(in view: NSView) -> [NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popups)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func capture(_ hosting: NSView, scheme: ColorScheme, failure: Bool = false) throws -> URL? {
        let directory: URL
        if let path = ProcessInfo.processInfo.environment["MACAROK_SNAPSHOT_DIRECTORY"], !path.isEmpty {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else if failure {
            directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".build/native-test-failures", isDirectory: true)
        } else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        hosting.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let suffix = scheme == .light ? "light" : "dark"
        let destination = directory.appendingPathComponent("playing-auto-switch-settings-\(failure ? "failure-" : "")\(suffix).png")
        try data.write(to: destination, options: .atomic)
        return destination
    }
}
