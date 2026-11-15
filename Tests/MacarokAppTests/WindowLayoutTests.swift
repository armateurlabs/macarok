import AppKit
import MacarokCore
import SwiftUI
import XCTest
@testable import MacarokApp

@MainActor
final class WindowLayoutTests: XCTestCase {
    func testEmptyPanelsFillWindowAndStayAlignedWhileResizing() async throws {
        try await assertLayout(state: .noSources)
    }

    func testConfiguredEmptySourceFillsWindow() async throws {
        try await assertLayout(state: .emptySource)
    }

    func testPopulatedLibraryWithEmptyQueueFillsWindow() async throws {
        try await assertLayout(state: .emptyQueue)
    }

    func testUnmatchedSearchFillsLibraryPanel() async throws {
        try await assertLayout(state: .unmatchedSearch)
    }

    private enum LibraryState { case noSources, emptySource, emptyQueue, unmatchedSearch }

    private func assertLayout(state: LibraryState) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokLayout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("layout.sqlite"))
        if state != .noSources {
            let source = SourceRecord(id: "layout-source", kind: .local, name: "Layout Test", location: directory.absoluteString)
            try store.saveSource(source)
            if state == .emptyQueue || state == .unmatchedSearch {
                try store.upsertTracks([TrackRecord(id: "layout-track", sourceID: source.id, title: "Example Track",
                                                    artist: "Example Artist", album: "Example Album", duration: 120, format: "FLAC")])
            }
        }
        let model = AppModel(store: store, preferences: AppPreferences(), registerSystemControls: false)
        await model.start()
        if state == .unmatchedSearch {
            model.search = "no matching tracks"
            for _ in 0..<100 {
                if model.displayedTracks.isEmpty { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(model.displayedTracks.isEmpty)
        }

        for scheme in [ColorScheme.light, .dark] {
            let hosting = NSHostingView(rootView: MainWindow(model: model)
                .frame(minWidth: 1050, minHeight: 680)
                .environment(\.colorScheme, scheme))
            hosting.sizingOptions = []
            hosting.autoresizingMask = [.width, .height]
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 680),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { window.contentView = nil; window.close() }

            for size in [NSSize(width: 1050, height: 680), NSSize(width: 1270, height: 1000),
                         NSSize(width: 1700, height: 720), NSSize(width: 1050, height: 680)] {
                window.setContentSize(size)
                for _ in 0..<8 {
                    hosting.layoutSubtreeIfNeeded()
                    await Task.yield()
                    try await Task.sleep(for: .milliseconds(20))
                }
                try assertPanelsFillContent(hosting, size: size)
                XCTAssertFalse(window.isVisible)
            }
        }
    }

    private func assertPanelsFillContent(_ hosting: NSView, size: NSSize,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        func splitView(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count == 3 { return split }
            return view.subviews.lazy.compactMap { splitView(in: $0) }.first
        }
        let split = try XCTUnwrap(splitView(in: hosting), "The three-panel split view must exist.", file: file, line: line)
        let frame = split.convert(split.bounds, to: hosting)
        let top = hosting.isFlipped ? frame.minY : hosting.bounds.height - frame.maxY
        XCTAssertLessThan(top, 100, "Panels must start directly below the transport bar: \(frame).", file: file, line: line)
        XCTAssertGreaterThan(frame.height, size.height - 130, "Panels must fill the area above the status bar: \(frame).", file: file, line: line)
        for pane in split.arrangedSubviews {
            XCTAssertEqual(pane.frame.minY, 0, accuracy: 1, "Pane headers must share the split view's top edge.", file: file, line: line)
            XCTAssertEqual(pane.frame.height, split.bounds.height, accuracy: 1, "Every pane must use the full available height.", file: file, line: line)
        }
    }
}
