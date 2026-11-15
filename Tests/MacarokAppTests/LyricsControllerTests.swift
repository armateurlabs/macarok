import Foundation
import XCTest
import MacarokCore
import MacarokMetadata
@testable import MacarokApp

@MainActor
final class LyricsControllerTests: XCTestCase {
    func testObsoleteRequestCannotReplaceNewTrackAndForegroundRemainsResponsive() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = LyricsReadGate()
        let controller = LyricsController(model: fixture.model, localReader: { track in
            if track.id == "first" { await gate.wait() }
            return .init(plainText: track.title, source: .sidecar)
        })
        let old = Task { await controller.load(track: fixture.first) }
        for _ in 0..<100 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let entered = await gate.hasEntered()
        XCTAssertTrue(entered)
        XCTAssertEqual(controller.state, .loading)
        // Executing these foreground mutations while I/O is held is the responsiveness check.
        fixture.model.libraryView = .albums
        await controller.load(track: fixture.second)
        XCTAssertEqual(controller.plainText, fixture.second.title)
        await gate.release()
        await old.value
        XCTAssertEqual(controller.track?.id, fixture.second.id)
        XCTAssertEqual(controller.plainText, fixture.second.title)
    }

    func testHighlightTracksPauseSeekAndDuplicateTimesWithoutReparsing() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = LyricsController(model: fixture.model, localReader: { _ in
            LRCParser.parse("[offset:200]\n[00:01.200]First\n[00:02.200]Second\n[00:02.200]Translation\n[00:03.200]Third")
        })
        await controller.load(track: fixture.first)
        XCTAssertNil(controller.activeLineID(at: 0.5))
        XCTAssertEqual(controller.activeLineID(at: 1), 0)
        XCTAssertEqual(controller.activeLineID(at: 2), 2)
        XCTAssertEqual(controller.activeLineID(at: 10), 3)
        XCTAssertEqual(controller.activeLineID(at: 1.5), 0)
        XCTAssertEqual(controller.activeLineID(at: 1.5), 0)
        XCTAssertNil(controller.activeLineID(at: .nan))
    }

    func testEditorRetainsOriginalTargetAcrossTrackAndScopeChanges() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = LyricsController(model: fixture.model, localReader: { _ in .init(plainText: "Original", source: .sidecar) })
        await controller.load(track: fixture.first)
        controller.openEditor()
        controller.editedText = "[00:01]User correction"
        fixture.model.libraryScope = .all
        await controller.load(track: fixture.second)
        await controller.saveEditedLyrics()
        XCTAssertFalse(controller.showsEditor)
        XCTAssertEqual(controller.track?.id, fixture.second.id)
        XCTAssertEqual(controller.plainText, "Original")
        let cached = try XCTUnwrap(fixture.store.cachedLyrics(for: .init(track: fixture.first)))
        XCTAssertTrue(cached.isManual)
        XCTAssertEqual(cached.result.document?.plainText, "User correction")
        XCTAssertEqual(fixture.model.libraryScope, .all)
        await controller.load(track: fixture.first)
        XCTAssertEqual(controller.plainText, "User correction")
    }

    func testSaveFailureRetainsCacheAndReportsPartialWrite() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = LyricsController(model: fixture.model, localReader: { _ in LRCParser.parse("[00:01]Retained") },
                                          fileWriter: { _, track in
            throw LyricsFileWriteError(savedURLs: [track.url!], failedURL: track.url!.appendingPathExtension("lrc"), reason: "Read-only folder")
        })
        await controller.load(track: fixture.first)
        XCTAssertTrue(controller.canSaveToFiles)
        await controller.saveToFiles()
        XCTAssertEqual(controller.state, .loaded)
        XCTAssertTrue(controller.notice?.contains("Read-only folder") == true)
        XCTAssertEqual(try fixture.store.cachedLyrics(for: .init(track: fixture.first))?.result.document?.plainText, "Retained")
    }

    func testCancelRejectsLateResultsAndRequestKeysIncludeOriginAndMetadata() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = LyricsReadGate()
        let controller = LyricsController(model: fixture.model, localReader: { _ in await gate.wait(); return .init(plainText: "Late", source: .sidecar) })
        let task = Task { await controller.load(track: fixture.first) }
        for _ in 0..<100 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(5)) }
        controller.cancel()
        await gate.release(); await task.value
        XCTAssertNotEqual(controller.state, .loaded)
        var changed = fixture.first
        changed.sourceID = "other"
        XCTAssertNotEqual(LyricsController.requestKey(for: changed), LyricsController.requestKey(for: fixture.first))
        changed = fixture.first; changed.title = "Edited"
        XCTAssertNotEqual(LyricsController.requestKey(for: changed), LyricsController.requestKey(for: fixture.first))
    }

    func testManualEditUpdatesDisplayedIdentityAfterConcurrentMetadataChange() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = LyricsController(model: fixture.model, localReader: { _ in .init(plainText: "Original", source: .sidecar) })
        await controller.load(track: fixture.first)
        controller.openEditor(); controller.editedText = "Correction"
        var updated = fixture.first; updated.title = "Corrected metadata"
        try fixture.store.upsertTracks([updated])
        await controller.load(track: updated)
        await controller.saveEditedLyrics()
        XCTAssertEqual(controller.track?.title, updated.title)
        XCTAssertEqual(controller.plainText, "Correction")
        XCTAssertEqual(try fixture.store.cachedLyrics(for: .init(track: updated))?.result.document?.plainText, "Correction")
    }

    func testOnlyUnavailableOptionalEndpointsPermitSilentServerFallback() {
        XCTAssertTrue(LyricsController.isOptionalLyricsUnavailable(SourceNetworkError.httpStatus(404)))
        XCTAssertTrue(LyricsController.isOptionalLyricsUnavailable(OpenSubsonicError(code: 0, message: "Unknown method")))
        XCTAssertTrue(LyricsController.isOptionalLyricsUnavailable(OpenSubsonicError(code: 70, message: "Data not found")))
        XCTAssertFalse(LyricsController.isOptionalLyricsUnavailable(OpenSubsonicError(code: 40, message: "Wrong password")))
        XCTAssertFalse(LyricsController.isOptionalLyricsUnavailable(SourceNetworkError.httpStatus(429)))
        XCTAssertFalse(LyricsController.isOptionalLyricsUnavailable(SourceNetworkError.invalidResponse))
        XCTAssertFalse(LyricsController.isOptionalLyricsUnavailable(URLError(.networkConnectionLost)))
    }

    private func makeFixture() throws -> (directory: URL, store: LibraryStore, model: AppModel, first: TrackRecord, second: TrackRecord) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LyricsController-\(UUID().uuidString)")
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let source = SourceRecord(id: "local", kind: .local, name: "Local", location: directory.path)
        try store.saveSource(source)
        let first = TrackRecord(id: "first", sourceID: source.id, title: "First", fileURL: directory.appendingPathComponent("first.flac").path)
        let second = TrackRecord(id: "second", sourceID: source.id, title: "Second", fileURL: directory.appendingPathComponent("second.flac").path)
        try store.upsertTracks([first, second])
        let model = AppModel(store: store, registerSystemControls: false)
        model.sources = [source]
        return (directory, store, model, first, second)
    }
}

private actor LyricsReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func hasEntered() -> Bool { entered }
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
