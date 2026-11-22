import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import MacarokApp

final class AboutSettingsViewTests: XCTestCase {
    @MainActor
    func testVersionShowsTheFullReleaseVersionAndBuild() throws {
        func bundle(_ info: [String: String]) throws -> Bundle {
            let app = FileManager.default.temporaryDirectory.appendingPathComponent("About-\(UUID().uuidString).app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: app) }
            try PropertyListSerialization.data(fromPropertyList: info.merging(["CFBundleIdentifier": "test.about.\(UUID().uuidString)"]) { a, _ in a },
                                               format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            return try XCTUnwrap(Bundle(url: app))
        }
        let release = try bundle(["CFBundleShortVersionString": "0.9.4", "CFBundleVersion": "7", "CFBundleGetInfoString": "Macarok 0.9.4-beta.1"])
        XCTAssertEqual(AboutSettingsView(bundle: release).versionText, "Version 0.9.4-beta.1 (7)", "A release build shows its prerelease suffix.")
        let local = try bundle(["CFBundleShortVersionString": "0.9.3", "CFBundleVersion": "3"])
        XCTAssertEqual(AboutSettingsView(bundle: local).versionText, "Version 0.9.3 (3)")
    }

    @MainActor
    func testRequestedTabIsShownOnceWhenSettingsAppears() async throws {
        _ = NSApplication.shared
        let model = AppModel(registerSystemControls: false)
        model.requestedSettingsTab = .about
        let hosting = NSHostingView(rootView: SettingsView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 555), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        for _ in 0..<15 where model.requestedSettingsTab != nil { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.requestedSettingsTab, "Settings consumes the request, so a later plain opening keeps the user's tab.")
    }

    func testUpdaterStartsOnlyInAnInstalledAppThatDeclaresItsFeedAndKey() throws {
        func bundle(_ name: String, _ info: [String: String]) throws -> Bundle {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Updater-\(UUID().uuidString)").appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            try PropertyListSerialization.data(fromPropertyList: info.merging(["CFBundleIdentifier": "test.updater.\(UUID().uuidString)"]) { a, _ in a },
                                               format: .xml, options: 0).write(to: root.appendingPathComponent("Contents/Info.plist"))
            return try XCTUnwrap(Bundle(url: root))
        }
        let declared = ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "c2lnbmluZy1rZXk="]
        XCTAssertTrue(AppUpdater.canUpdate(try bundle("Macarok.app", declared)))
        XCTAssertFalse(AppUpdater.canUpdate(try bundle("Macarok.xctest", declared)), "Tests and swift run never start Sparkle.")
        XCTAssertFalse(AppUpdater.canUpdate(try bundle("Macarok.app", ["SUFeedURL": "https://example.com/appcast.xml"])),
                       "Without the public key, an update could not be verified.")
    }

    func testLastCheckTextNamesTodayAndYesterday() throws {
        var calendar = Calendar.current; calendar.timeZone = .current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 13, minute: 45)))
        XCTAssertEqual(UpdateStatusText.lastCheck(nil, now: now), "Not checked yet")
        XCTAssertTrue(UpdateStatusText.lastCheck(now.addingTimeInterval(-3_600), now: now).hasPrefix("Last checked today at "))
        XCTAssertTrue(UpdateStatusText.lastCheck(now.addingTimeInterval(-86_400), now: now).hasPrefix("Last checked yesterday at "))
        XCTAssertFalse(UpdateStatusText.lastCheck(now.addingTimeInterval(-5 * 86_400), now: now).contains("today"))
    }
}
