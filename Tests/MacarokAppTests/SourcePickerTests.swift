import AppKit
import MacarokCore
import SwiftUI
import XCTest
@testable import MacarokApp

@MainActor
final class SourcePickerTests: XCTestCase {
    func testNativePickerShowsSourceIconsAndCheckedSelectionWithoutChangingQueue() async throws {
        _ = NSApplication.shared
        let local = SourceRecord(id: "picker-local", kind: .local, name: "Local Files", location: "/tmp/music")
        let remote = SourceRecord(id: "picker-remote", kind: .openSubsonic, name: "A very long music server library name", location: "https://music.invalid")
        let podcast = SourceRecord(id: "picker-podcast", kind: .podcasts, name: "Podcasts", location: "https://podcast.invalid/feed.xml")
        let model = AppModel(preferences: AppPreferences(), registerSystemControls: false)
        model.sources = [local, remote, RadioLibrary.source, podcast]
        model.libraryScope = .all
        model.queue = [QueueItem(track: TrackRecord(id: "picker-queue", sourceID: local.id, title: "Queued Track"))]
        let originalQueue = model.queue

        for scheme in [ColorScheme.light, .dark] {
            let hosting = NSHostingView(rootView: PanelHeader { SourceMenu(model: model) }.environment(\.colorScheme, scheme))
            hosting.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 245, height: 43), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { window.contentView = nil; window.close() }
            for _ in 0..<10 { hosting.layoutSubtreeIfNeeded(); await Task.yield() }
            let picker = try XCTUnwrap(findPicker(in: hosting))
            XCTAssertEqual(picker.numberOfItems, 5)
            XCTAssertEqual(picker.itemTitle(at: 0), "All Sources")
            XCTAssertTrue(picker.itemArray.allSatisfy { $0.image != nil })
            XCTAssertEqual(picker.item(at: 4)?.image?.isTemplate, true)
            XCTAssertTrue(picker.isEnabled)
            XCTAssertFalse(picker.pullsDown)
            XCTAssertGreaterThan(picker.frame.width, 150, "The native picker must fill the header's usable width.")
            XCTAssertLessThanOrEqual(picker.frame.height, 42)

            for (index, expected) in [(0, LibraryScope.all), (2, .source(remote.id)), (3, .source(RadioLibrary.sourceID)), (4, .source(podcast.id))] {
                picker.selectItem(at: index)
                picker.sendAction(try XCTUnwrap(picker.action), to: picker.target)
                for _ in 0..<10 { hosting.layoutSubtreeIfNeeded(); await Task.yield() }
                XCTAssertEqual(model.libraryScope, expected)
                XCTAssertEqual(picker.indexOfSelectedItem, index)
                XCTAssertEqual(picker.itemArray.filter { $0.state == .on }.count, 1)
                XCTAssertEqual(picker.item(at: index)?.state, .on)
                XCTAssertEqual(model.queue, originalQueue)
            }
            XCTAssertFalse(window.isVisible)
        }
    }

    private func findPicker(in view: NSView) -> NSPopUpButton? {
        if let picker = view as? NSPopUpButton { return picker }
        return view.subviews.lazy.compactMap { self.findPicker(in: $0) }.first
    }
}
