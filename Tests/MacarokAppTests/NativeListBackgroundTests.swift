import AppKit
import Observation
import SwiftUI
import XCTest
@testable import MacarokApp

@MainActor
final class NativeListBackgroundTests: XCTestCase {
    func testRealListAlternatesOnlyExistingRowsAndUpdatesAfterQueueChangesAndResize() async throws {
        _ = NSApplication.shared
        for scheme in [ColorScheme.light, .dark] {
            let state = ListBackgroundFixture()
            let appearance = try XCTUnwrap(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
            let hosting = NSHostingView(rootView: ListBackgroundFixtureView(state: state)
                .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "en_US")))
            hosting.sizingOptions = []
            hosting.autoresizingMask = [.width, .height]
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 360), styleMask: [.borderless, .resizable], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            hosting.appearance = appearance
            window.contentView = hosting
            window.setContentSize(NSSize(width: 320, height: 360))
            defer { window.contentView = nil; window.close() }
            try await settle(hosting)
            let table = try XCTUnwrap(descendants(in: hosting).compactMap { $0 as? NSTableView }.first)
            XCTAssertEqual(table.numberOfRows, 2)
            XCTAssertTrue(table.usesAlternatingRowBackgroundColors, "Real rows must retain native alternating styling.")
            let delegate = table.delegate as AnyObject?
            let dataSource = table.dataSource as AnyObject?
            try assertActualAlternationAndUniformEmptyArea(table: table, hosting: hosting,
                snapshotName: scheme == .light ? "list-rows-light.png" : "list-rows-dark.png")
            let probe = try XCTUnwrap(descendants(in: hosting).compactMap { $0 as? NativeListBackgroundProbe }.first)
            XCTAssertNil(probe.hitTest(NSPoint(x: probe.bounds.midX, y: probe.bounds.midY)))
            XCTAssertFalse(probe.acceptsFirstResponder)

            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            try await settle(hosting)
            XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1), "Native selection must survive background updates.")
            state.count = 4; state.revision += 1
            try await settle(hosting)
            XCTAssertEqual(table.numberOfRows, 4)
            XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
            XCTAssertTrue((table.delegate as AnyObject?) === delegate)
            XCTAssertTrue((table.dataSource as AnyObject?) === dataSource)
            table.deselectAll(nil)
            try await settle(hosting)
            try assertActualAlternationAndUniformEmptyArea(table: table, hosting: hosting)

            state.count = 1; state.revision += 1
            window.setContentSize(NSSize(width: 400, height: 440))
            try await settle(hosting)
            XCTAssertEqual(table.numberOfRows, 1)
            try assertActualAlternationAndUniformEmptyArea(table: table, hosting: hosting)
            state.count = 0; state.revision += 1
            try await settle(hosting)
            XCTAssertEqual(table.numberOfRows, 0)
            try assertActualAlternationAndUniformEmptyArea(table: table, hosting: hosting)
            XCTAssertFalse(window.isVisible)
        }
    }

    func testNativeOutlineExpansionAndCollapseRecolorRealRowsWithoutReplacingItsDelegate() async throws {
        _ = NSApplication.shared
        let provider = OutlineBackgroundFixture()
        let table = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 320, height: 360))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        column.width = 320
        table.addTableColumn(column)
        table.outlineTableColumn = column
        table.headerView = nil
        table.rowHeight = 30
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = provider; table.dataSource = provider
        let scroll = NSScrollView(frame: table.frame)
        scroll.documentView = table
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        let coordinator = NativeListBackground.Coordinator()
        defer { coordinator.detach(); window.contentView = nil; window.close() }
        table.reloadData()
        coordinator.attach(to: table)
        coordinator.refresh()
        try await settle(scroll)
        coordinator.refresh()
        XCTAssertEqual(table.numberOfRows, 2)
        let mask = try XCTUnwrap(scroll.subviews.compactMap { $0 as? NativeListEmptyAreaMask }.first)
        let initialEmptyTop = mask.emptyArea.minY
        XCTAssertNil(mask.hitTest(NSPoint(x: 10, y: 10)))
        table.expandItem(provider.roots[0])
        try await settle(scroll)
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertGreaterThan(mask.emptyArea.minY, initialEmptyTop, "The mask must retreat below newly expanded real rows.")
        table.collapseItem(provider.roots[0])
        try await settle(scroll)
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(mask.emptyArea.minY, initialEmptyTop, accuracy: 1)
        XCTAssertTrue(table.usesAlternatingRowBackgroundColors)
        XCTAssertTrue(table.delegate === provider)
        XCTAssertTrue(table.dataSource === provider)
        XCTAssertFalse(window.isVisible)
    }

    private func assertActualAlternationAndUniformEmptyArea(table: NSTableView, hosting: NSView, snapshotName: String? = nil,
                                                          file: StaticString = #filePath, line: UInt = #line) throws {
        hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds), file: file, line: line)
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let snapshotName, let path = ProcessInfo.processInfo.environment["MACAROK_SNAPSHOT_DIRECTORY"], !path.isEmpty {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), file: file, line: line)
            try data.write(to: directory.appendingPathComponent(snapshotName), options: .atomic)
        }
        let viewport = table.enclosingScrollView?.contentView
        let visible = viewport.map { table.convert($0.bounds, from: $0) } ?? table.visibleRect
        let sampleX = visible.minX + visible.width * 0.75
        func color(_ y: CGFloat) throws -> NSColor {
            let point = table.convert(NSPoint(x: sampleX, y: y), to: hosting)
            let x = min(bitmap.pixelsWide - 1, max(0, Int(point.x / hosting.bounds.width * CGFloat(bitmap.pixelsWide))))
            let topY = hosting.isFlipped ? point.y : hosting.bounds.height - point.y
            let y = min(bitmap.pixelsHigh - 1, max(0, Int(topY / hosting.bounds.height * CGFloat(bitmap.pixelsHigh))))
            return try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), file: file, line: line)
        }
        if table.numberOfRows > 1 {
            let first = try color(table.rect(ofRow: 0).midY)
            let second = try color(table.rect(ofRow: 1).midY)
            XCTAssertGreaterThan(distance(first, second), 0.005, "Actual native rows must visibly alternate.", file: file, line: line)
        }
        let end = table.numberOfRows > 0 ? table.rect(ofRow: table.numberOfRows - 1).maxY : visible.minY
        let start = max(end + 12, visible.minY + 12)
        let bottom = visible.maxY - 20
        guard bottom > start + 30 else { return }
        let baseline = try color(start)
        for y in stride(from: start, through: bottom, by: 11) {
            XCTAssertLessThan(distance(baseline, try color(y)), 0.005,
                              "Space after the last actual row must stay uniformly colored, without phantom stripes.", file: file, line: line)
        }
        let mask = try XCTUnwrap(table.enclosingScrollView?.subviews.compactMap { $0 as? NativeListEmptyAreaMask }.first, file: file, line: line)
        XCTAssertNil(mask.hitTest(NSPoint(x: mask.bounds.midX, y: mask.bounds.midY)), file: file, line: line)
        if table.numberOfRows > 0 {
            let last = mask.convert(table.rect(ofRow: table.numberOfRows - 1), from: table)
            XCTAssertGreaterThanOrEqual(mask.emptyArea.minY, last.maxY - 1, "The mask must never cover a real row.", file: file, line: line)
        }
    }

    private func distance(_ first: NSColor, _ second: NSColor) -> CGFloat {
        max(abs(first.redComponent - second.redComponent), max(abs(first.greenComponent - second.greenComponent), abs(first.blueComponent - second.blueComponent)))
    }

    private func settle(_ view: NSView) async throws {
        for _ in 0..<14 {
            view.layoutSubtreeIfNeeded()
            for table in descendants(in: view).compactMap({ $0 as? NSTableView }) {
                for index in 0..<table.numberOfRows { _ = table.rowView(atRow: index, makeIfNecessary: true) }
            }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(15))
        }
        view.layoutSubtreeIfNeeded()
    }

    private func descendants(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants(in: $0) } }
}

@MainActor @Observable
private final class ListBackgroundFixture {
    var count = 2
    var revision = 0
    var selection: Int?
}

private struct ListBackgroundFixtureView: View {
    @Bindable var state: ListBackgroundFixture
    var body: some View {
        List(selection: $state.selection) {
            ForEach(0..<state.count, id: \.self) { index in
                Text("Entry \(index + 1)").frame(height: 30).tag(index)
            }
        }.listStyle(.inset(alternatesRowBackgrounds: true))
            .background(NativeListBackground(revision: state.revision))
    }
}

@MainActor
private final class OutlineBackgroundFixture: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Node: NSObject {
        let title: String
        let children: [Node]
        init(_ title: String, children: [Node] = []) { self.title = title; self.children = children }
    }
    let roots = [Node("Artist", children: [Node("Album")]), Node("Second artist")]
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? Node)?.children ?? roots)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Node)?.children.isEmpty ?? true) }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        NSTextField(labelWithString: (item as? Node)?.title ?? "")
    }
}
