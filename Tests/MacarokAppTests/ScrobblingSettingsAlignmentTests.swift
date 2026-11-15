import AppKit
import MacarokCore
import SwiftUI
import XCTest
@testable import MacarokApp

@MainActor
final class ScrobblingSettingsAlignmentTests: XCTestCase {
    func testGroupedSettingsKeepNativeCredentialTextFieldsLeftAligned() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokCredentialAlignment-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let credentials = AlignmentPreviewCredentials()
        let controller = ScrobblingController(store: store, credentials: credentials, transport: { _ in
            XCTFail("Rendering credentials must never contact Last.fm.")
            throw CancellationError()
        })
        await controller.start()

        for scheme in [ColorScheme.light, .dark] {
            let hosting = NSHostingView(rootView: ScrobblingSettingsView(controller: controller, sources: [])
                .frame(width: 650, height: 555)
                .environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.layoutDirection, .leftToRight))
            hosting.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 555), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { window.contentView = nil; window.close() }
            for _ in 0..<12 { hosting.layoutSubtreeIfNeeded(); await Task.yield(); try await Task.sleep(for: .milliseconds(20)) }

            let fields = editableFields(in: hosting)
            let key = try XCTUnwrap(fields.first { $0.stringValue == credentials.application.apiKey })
            let secret = try XCTUnwrap(fields.first { $0.stringValue == credentials.application.sharedSecret })
            for field in [key, secret] {
                let resolvesLeft = field.alignment == .left ||
                    (field.alignment == .natural && field.userInterfaceLayoutDirection == .leftToRight)
                XCTAssertTrue(resolvesLeft, "The grouped Form must keep credential text at the left edge; found \(field.alignment).")
            }
            XCTAssertGreaterThan(key.frame.width, 160)
            XCTAssertGreaterThan(secret.frame.width, 160)
            XCTAssertFalse(window.isVisible)
        }
    }

    private func editableFields(in view: NSView) -> [NSTextField] {
        let field = (view as? NSTextField).flatMap { $0.isEditable ? $0 : nil }
        return (field.map { [$0] } ?? []) + view.subviews.flatMap { self.editableFields(in: $0) }
    }
}

private struct AlignmentPreviewCredentials: LastFMCredentialStorage {
    let application = LastFMAppCredentials(apiKey: String(repeating: "a", count: 32), sharedSecret: String(repeating: "b", count: 32))
    func load() throws -> LastFMCredentialRecord? { LastFMCredentialRecord(application: application) }
    func save(_ credentials: LastFMCredentialRecord) throws { }
    func delete() throws { }
}
