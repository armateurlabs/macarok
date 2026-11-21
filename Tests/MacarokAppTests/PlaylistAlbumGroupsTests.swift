import AppKit
import Foundation
import MacarokCore
import SwiftUI
import XCTest
@testable import MacarokApp

final class PlaylistAlbumGroupsTests: XCTestCase {
    func testOnlyAdjacentEntriesFromTheSameSourceAlbumShareAHeader() {
        let a1 = entry("a1", album: "A")
        var loose = entry("loose", album: "Loose"); loose.track.albumID = ""
        // Duplicate tracks are separate queue entries with their own UUIDs.
        let queue = [a1, entry("a2", album: "A"), entry("a2", album: "A"), entry("a1", album: "A", source: "other"),
                     entry("s", album: "S"), entry("a1", album: "A"), loose,
                     entry("radio-1", album: "radio"), entry("radio-2", album: "radio")]
        let rows = PlaylistAlbumGrouping.rows(queue, grouped: true) { $0.albumID == "radio" }
        XCTAssertEqual(rows.map(describe), ["H0..<3", "G0", "G1", "G2", "S3", "S4", "S5", "P6", "P7", "P8"])
        guard case .header(let header) = rows[0] else { return XCTFail("Expected an album header.") }
        XCTAssertEqual(header.firstEntryID, a1.id)
        XCTAssertEqual(header.duration, 180)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "Duplicate tracks keep distinct entry identities.")

        let compact = PlaylistAlbumGrouping.rows(queue, grouped: false) { _ in false }
        XCTAssertEqual(compact.map(describe), (0..<queue.count).map { "P\($0)" })
    }

    func testVisualOffsetsMapToQueueOffsetsAroundHeaders() {
        let queue = [entry("a1", album: "A"), entry("a2", album: "A"), entry("b1", album: "B"), entry("b2", album: "B")]
        let rows = PlaylistAlbumGrouping.rows(queue, grouped: true) { _ in false }
        // Rows: H(A) a1 a2 H(B) b1 b2
        XCTAssertEqual(PlaylistAlbumGrouping.queueOffsets(IndexSet([0, 2, 5]), rows: rows), IndexSet([1, 3]))
        XCTAssertEqual(PlaylistAlbumGrouping.queueDestination(0, rows: rows), 0)
        XCTAssertEqual(PlaylistAlbumGrouping.queueDestination(3, rows: rows), 2, "Before album B's header is after A.")
        XCTAssertEqual(PlaylistAlbumGrouping.queueDestination(4, rows: rows), 2, "After B's header is before its first entry.")
        XCTAssertEqual(PlaylistAlbumGrouping.queueDestination(6, rows: rows), 4)
        XCTAssertEqual(PlaylistAlbumGrouping.queueDestination(99, rows: rows), 4)
    }

    @MainActor
    func testMovingAndDeletingThroughGroupedRowsEditsTheRealQueue() {
        let model = AppModel(registerSystemControls: false)
        model.queue = [entry("a1", album: "A"), entry("a2", album: "A"), entry("b1", album: "B"), entry("b2", album: "B")]
        let original = model.queue
        var rows = PlaylistAlbumGrouping.rows(model.queue, grouped: true) { _ in false }
        // Drag b2 (row 5) to just after album A's header (row 1).
        model.moveQueue(from: PlaylistAlbumGrouping.queueOffsets([5], rows: rows), to: PlaylistAlbumGrouping.queueDestination(1, rows: rows))
        XCTAssertEqual(model.queue.map(\.id), [original[3], original[0], original[1], original[2]].map(\.id))
        rows = PlaylistAlbumGrouping.rows(model.queue, grouped: true) { _ in false }
        XCTAssertEqual(rows.map(describe), ["S0", "H1..<3", "G1", "G2", "S3"])
        model.removeQueue(PlaylistAlbumGrouping.queueOffsets([1, 2], rows: rows))
        XCTAssertEqual(model.queue.map(\.id), [original[3], original[1], original[2]].map(\.id))
    }

    @MainActor
    func testNativePlaylistAddsHeaderRowsOnlyWhileTheOptionIsEnabled() async throws {
        _ = NSApplication.shared
        let model = AppModel(registerSystemControls: false)
        model.queue = [entry("a1", album: "A"), entry("a2", album: "A"), entry("b1", album: "B")]
        model.settings.playlistAlbumGroups = false
        let hosting = NSHostingView(rootView: QueuePane(model: model, player: model.player).frame(width: 330, height: 400))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 330, height: 400)
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        func table() throws -> NSTableView {
            func find(_ view: NSView) -> NSTableView? {
                if let table = view as? NSTableView { return table }
                return view.subviews.lazy.compactMap(find).first
            }
            return try XCTUnwrap(find(hosting))
        }
        func settle() async throws {
            for _ in 0..<15 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        try await settle()
        XCTAssertEqual(try table().numberOfRows, 3)
        model.settings.playlistAlbumGroups = true
        try await settle()
        XCTAssertEqual(try table().numberOfRows, 4, "Album A gains one header; the lone album B entry stays a single row.")
        model.selectedQueueIDs = [model.queue[1].id]
        try await settle()
        XCTAssertEqual(try table().selectedRow, 2, "Selection follows queue UUIDs past the header row.")
        model.settings.playlistAlbumGroups = false
        try await settle()
        XCTAssertEqual(try table().numberOfRows, 3)
        XCTAssertEqual(model.selectedQueueIDs, [model.queue[1].id])
    }

    @MainActor
    func testAllSourcesNamesTheGroupSourceInItsHeaderWithoutTallerEntries() async throws {
        _ = NSApplication.shared
        let model = AppModel(registerSystemControls: false)
        model.queue = [entry("a1", album: "A"), entry("a2", album: "A"), entry("b1", album: "B")]
        let hosting = NSHostingView(rootView: QueuePane(model: model, player: model.player).frame(width: 330, height: 400))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 330, height: 400)
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        func heights() async throws -> [CGFloat] {
            for _ in 0..<15 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            func find(_ view: NSView) -> NSTableView? {
                if let table = view as? NSTableView { return table }
                return view.subviews.lazy.compactMap(find).first
            }
            let table = try XCTUnwrap(find(hosting))
            return (0..<table.numberOfRows).map { table.rect(ofRow: $0).height }
        }
        let singleSource = try await heights()
        XCTAssertEqual(singleSource.count, 4)
        model.libraryScope = .all
        XCTAssertTrue(model.playlistShowsSources)
        let allSources = try await heights()
        XCTAssertEqual(allSources[1], singleSource[1], accuracy: 0.5, "Grouped entries gain no source line.")
        XCTAssertEqual(allSources[2], singleSource[2], accuracy: 0.5)
        XCTAssertEqual(allSources[0], singleSource[0], accuracy: 0.5, "The header badge shares the artist line.")
        model.settings.playlistShowsSources = false
        XCTAssertFalse(model.playlistShowsSources)
        model.libraryScope = .source("source")
        model.settings.playlistShowsSources = true
        XCTAssertFalse(model.playlistShowsSources, "Badges appear only when browsing All Sources.")
    }

    @MainActor
    func testSelectQueueGroupSelectsEveryTrackOfTheAlbum() {
        let model = AppModel(registerSystemControls: false)
        let a1 = entry("a1", album: "A"), a2 = entry("a2", album: "A"), b1 = entry("b1", album: "B")
        model.queue = [a1, a2, b1]
        model.selectQueueGroup(firstEntryID: a1.id, count: 2, adding: false)
        XCTAssertEqual(model.selectedQueueIDs, [a1.id, a2.id])
        // Offsets are re-resolved by entry identity, and a stale count is bounded by the queue's end.
        model.selectQueueGroup(firstEntryID: a2.id, count: 9, adding: false)
        XCTAssertEqual(model.selectedQueueIDs, [a2.id, b1.id])
        model.selectQueueGroup(firstEntryID: a1.id, count: 2, adding: true)
        XCTAssertEqual(model.selectedQueueIDs, [a1.id, a2.id, b1.id], "Command-click adds the group.")
        model.selectQueueGroup(firstEntryID: UUID(), count: 2, adding: false)
        XCTAssertEqual(model.selectedQueueIDs, [a1.id, a2.id, b1.id], "A stale anchor selects nothing rather than the wrong rows.")
    }

    @MainActor
    func testIsQueueGroupSelectedRequiresEveryEntryOfTheGroup() {
        let model = AppModel(registerSystemControls: false)
        let a1 = entry("a1", album: "A"), a2 = entry("a2", album: "A"), b1 = entry("b1", album: "B")
        model.queue = [a1, a2, b1]
        XCTAssertFalse(model.isQueueGroupSelected(firstEntryID: a1.id, count: 2))
        model.selectedQueueIDs = [a1.id]
        XCTAssertFalse(model.isQueueGroupSelected(firstEntryID: a1.id, count: 2), "A partial group selection does not read as the album.")
        model.selectedQueueIDs = [a1.id, a2.id]
        XCTAssertTrue(model.isQueueGroupSelected(firstEntryID: a1.id, count: 2))
        XCTAssertFalse(model.isQueueGroupSelected(firstEntryID: b1.id, count: 1), "Other groups stay unselected.")
        model.selectedQueueIDs = [b1.id]
        XCTAssertTrue(model.isQueueGroupSelected(firstEntryID: b1.id, count: 1), "A single selected entry reads as selected.")
    }

    private func entry(_ id: String, album: String, source: String = "source") -> QueueItem {
        QueueItem(track: TrackRecord(id: id, sourceID: source, albumID: album, title: id, artist: "Artist",
                                     album: album, duration: 60))
    }

    private func describe(_ row: PlaylistRow) -> String {
        switch row {
        case .header(let header): "H\(header.offsets.lowerBound)..<\(header.offsets.upperBound)"
        case .entry(let index, _, let layout): (layout == .grouped ? "G" : layout == .single ? "S" : "P") + String(index)
        }
    }
}
