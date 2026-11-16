import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

@MainActor
final class PlayingAutoSwitchTests: XCTestCase {
    func testManualStartOverridesEarlierHomeNavigationAndPreservesDetailChoices() {
        let fixture = makeFixture()
        let model = fixture.model
        defer { model.stopPlayback(clearCurrent: true) }
        model.libraryScope = .source("source-a")
        model.contextMode = .lyrics
        model.contextTab = "Tags"
        model.selectHomeFilter(.mostPlayed)
        model.selectCenterPage(.home)

        model.playQueueItem(fixture.entries[0].id)

        XCTAssertEqual(model.centerPage, .playing)
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[0].track.id)
        XCTAssertEqual(model.contextMode, .lyrics)
        XCTAssertEqual(model.contextTab, "Tags")
        XCTAssertEqual(model.homeFilter, .mostPlayed)
        XCTAssertEqual(model.libraryScope, .source("source-a"))
    }

    func testAutomaticAdvanceAndRepeatKeepHomeWhileManualNextAndPreviousShowPlaying() {
        let fixture = makeFixture()
        let model = fixture.model
        defer { model.stopPlayback(clearCurrent: true) }
        model.playQueueItem(fixture.entries[0].id)
        model.selectCenterPage(.home)
        model.selectHomeFilter(.recentlyPlayed)
        model.contextMode = .wikipedia

        model.advance(manual: false)
        XCTAssertEqual(model.currentQueueID, fixture.entries[1].id)
        XCTAssertEqual(model.centerPage, .home)
        model.settings.repeatMode = .track
        model.advance(manual: false)
        XCTAssertEqual(model.currentQueueID, fixture.entries[1].id)
        XCTAssertEqual(model.centerPage, .home)

        model.advance()
        XCTAssertEqual(model.currentQueueID, fixture.entries[2].id)
        XCTAssertEqual(model.centerPage, .playing)
        model.selectCenterPage(.home)
        model.previous()
        XCTAssertEqual(model.currentQueueID, fixture.entries[1].id)
        XCTAssertEqual(model.centerPage, .playing)
        XCTAssertEqual(model.contextMode, .wikipedia)
        XCTAssertEqual(model.homeFilter, .recentlyPlayed)
    }

    func testOncePerLaunchIsConsumedAcrossLaterManualRequestsAndApplicationStops() {
        let fixture = makeFixture(mode: .oncePerLaunch)
        let model = fixture.model
        defer { model.stopPlayback(clearCurrent: true) }
        model.playQueueItem(fixture.entries[0].id)
        XCTAssertEqual(model.centerPage, .playing)
        model.selectCenterPage(.home)

        model.playQueueItem(fixture.entries[1].id)
        XCTAssertEqual(model.centerPage, .home)
        model.stopPlayback(clearCurrent: false)
        model.playQueueItem(fixture.entries[2].id)
        XCTAssertEqual(model.centerPage, .home)
    }

    func testOncePerLaunchHonorsEarlierNavigationAndChangingModesDoesNotRearmIt() {
        let fixture = makeFixture(mode: .oncePerLaunch)
        let model = fixture.model
        defer { model.stopPlayback(clearCurrent: true) }
        model.selectHomeFilter(.mostPlayed)
        model.playQueueItem(fixture.entries[0].id)
        XCTAssertEqual(model.centerPage, .home)
        XCTAssertEqual(model.homeFilter, .mostPlayed)

        model.settings.playingAutoSwitchMode = .manualTrackStart
        XCTAssertEqual(model.centerPage, .home, "Changing a preference must not navigate immediately.")
        model.playQueueItem(fixture.entries[1].id)
        XCTAssertEqual(model.centerPage, .playing)
        model.selectCenterPage(.home)
        model.settings.playingAutoSwitchMode = .oncePerLaunch
        model.playQueueItem(fixture.entries[2].id)
        XCTAssertEqual(model.centerPage, .home)
    }

    func testIntentionalCenterEntryHelpersProtectTheFirstLaunchStart() {
        let actions: [(String, @MainActor (AppModel, [QueueItem]) -> Void)] = [
            ("center page", { model, _ in model.selectCenterPage(.home) }),
            ("home filter", { model, _ in model.selectHomeFilter(.mostPlayed) }),
            ("playing submenu", { model, _ in model.selectContextMode(.lyrics) }),
            ("context tab", { model, _ in model.selectContextTab("Tags") }),
            ("library home", { model, _ in model.selectLibraryView(.home) }),
            ("track inspection", { model, entries in model.inspect(entries[2].track) }),
            ("album inspection", { model, entries in model.inspect(AlbumRecord(tracks: entries.map(\.track))) }),
            ("artist inspection", { model, _ in model.inspectArtist("Artist") }),
            ("folder inspection", { model, _ in model.inspectFolder("source-a/folder") })
        ]
        for (name, action) in actions {
            let fixture = makeFixture(mode: .oncePerLaunch)
            let model = fixture.model
            defer { model.stopPlayback(clearCurrent: true) }
            action(model, fixture.entries)
            // Restore the visible page without recording another UI action, so the marker
            // produced by this specific entry point is what suppresses navigation.
            model.centerPage = .home

            model.playQueueItem(fixture.entries[0].id)

            XCTAssertEqual(model.centerPage, .home, name)
            XCTAssertEqual(model.currentQueueID, fixture.entries[0].id, name)
        }
    }

    func testProgrammaticInspectionDoesNotProtectOrConsumeTheFirstLaunchStart() {
        let fixture = makeFixture(mode: .oncePerLaunch)
        let model = fixture.model
        defer { model.stopPlayback(clearCurrent: true) }
        model.inspect(fixture.entries[2].track, userInitiated: false)
        model.centerPage = .home

        model.playQueueItem(fixture.entries[0].id)

        XCTAssertEqual(model.centerPage, .playing)
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[0].track.id)
    }

    func testSessionModeRearmsAfterApplicationStopAndQueueCompletionOnly() {
        let fixture = makeFixture(mode: .playbackSessionStart)
        let model = fixture.model
        defer { model.stopPlayback(clearCurrent: true) }
        model.playQueueItem(fixture.entries[0].id)
        XCTAssertEqual(model.centerPage, .playing)
        model.selectCenterPage(.home)
        model.playQueueItem(fixture.entries[1].id)
        XCTAssertEqual(model.centerPage, .home, "The decoder's internal stop between tracks is not a new session.")

        model.stopPlayback(clearCurrent: false)
        model.playQueueItem(fixture.entries[2].id)
        XCTAssertEqual(model.centerPage, .playing)
        model.selectCenterPage(.home)
        model.advance(manual: false)
        XCTAssertEqual(model.player.state, .stopped)
        XCTAssertEqual(model.centerPage, .home)
        model.playQueueItem(fixture.entries[0].id)
        XCTAssertEqual(model.centerPage, .playing)
    }

    func testSessionModeKeepsNavigationMadeAfterStopAndConsumesItsOpportunity() {
        let fixture = makeFixture(mode: .playbackSessionStart)
        let model = fixture.model
        defer { model.stopPlayback(clearCurrent: true) }
        model.playQueueItem(fixture.entries[0].id)
        model.stopPlayback(clearCurrent: false)
        model.selectCenterPage(.home)
        model.selectHomeFilter(.recentlyAdded)

        model.playQueueItem(fixture.entries[1].id)
        XCTAssertEqual(model.centerPage, .home)
        model.playQueueItem(fixture.entries[2].id)
        XCTAssertEqual(model.centerPage, .home)
        XCTAssertEqual(model.homeFilter, .recentlyAdded)
    }

    func testInvalidRequestAndProgrammaticQueueRestorationDoNotConsumeLaunchOpportunity() {
        let fixture = makeFixture(mode: .oncePerLaunch)
        let model = fixture.model
        defer { model.stopPlayback(clearCurrent: true) }
        model.currentQueueID = fixture.entries[1].id
        model.restorePosition = 8
        model.playQueueItem(UUID())
        XCTAssertEqual(model.centerPage, .home)
        XCTAssertEqual(model.player.state, .stopped)
        XCTAssertEqual(model.restorePosition, 8)

        model.playQueueItem(fixture.entries[1].id)
        XCTAssertEqual(model.centerPage, .playing)
    }

    func testUndoRestoresParkedQueueWithoutNavigatingOrConsumingLaunchOpportunity() {
        let model = AppModel(preferences: AppPreferences(), registerSystemControls: false)
        model.settings.playingAutoSwitchMode = .oncePerLaunch
        defer { model.stopPlayback(clearCurrent: true) }
        model.add([track("a"), track("b")])
        let entries = model.queue
        model.currentQueueID = entries[1].id
        model.restorePosition = 7.5
        model.clearQueue()
        model.queueUndoManager.undo()
        XCTAssertEqual(model.queue.map(\.id), entries.map(\.id))
        XCTAssertEqual(model.currentQueueID, entries[1].id)
        XCTAssertEqual(model.restorePosition, 7.5)
        XCTAssertEqual(model.centerPage, .home)
        XCTAssertEqual(model.player.state, .stopped)

        model.playQueueItem(entries[1].id)
        XCTAssertEqual(model.centerPage, .playing)
    }

    func testSongAlbumAndArtworkEditorsKeepTheirOriginalTargetDuringManualStart() throws {
        for editor in ["song", "album", "artwork", "sheet"] {
            let fixture = makeFixture()
            let model = fixture.model
            defer { model.stopPlayback(clearCurrent: true) }
            model.currentQueueID = fixture.entries[0].id
            model.centerPage = .playing
            switch editor {
            case "song":
                model.beginMetadataEditing()
                let session = try XCTUnwrap(model.metadataEditingSession)
                session.draft.title = "Unfinished song correction"
            case "album":
                model.beginAlbumMetadataEditing()
                let session = try XCTUnwrap(model.albumMetadataEditingSession)
                session.draft.album = "Unfinished album correction"
            case "artwork": model.artworkTrack = fixture.entries[0].track
            default: model.editingTrack = fixture.entries[0].track
            }
            model.selectCenterPage(.home)

            model.playQueueItem(fixture.entries[1].id)

            XCTAssertEqual(model.centerPage, .home, editor)
            XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[0].track.id, editor)
            XCTAssertTrue(model.isEditingContext, editor)
            if editor == "song" { XCTAssertEqual(model.metadataEditingSession?.draft.title, "Unfinished song correction") }
            if editor == "album" { XCTAssertEqual(model.albumMetadataEditingSession?.draft.album, "Unfinished album correction") }
        }
    }

    func testProtectedEditorConsumesOneShotRatherThanDeferringNavigationUntilItCloses() {
        let fixture = makeFixture(mode: .oncePerLaunch)
        let model = fixture.model
        defer { model.stopPlayback(clearCurrent: true) }
        model.currentQueueID = fixture.entries[0].id
        model.artworkTrack = fixture.entries[0].track
        model.playQueueItem(fixture.entries[1].id)
        XCTAssertEqual(model.centerPage, .home)

        model.artworkTrack = nil
        XCTAssertEqual(model.centerPage, .home)
        model.playQueueItem(fixture.entries[2].id)
        XCTAssertEqual(model.centerPage, .home)
    }

    func testPausedPreparationResumesWithoutReopeningPlaying() {
        let fixture = makeFixture()
        let model = fixture.model
        defer { model.stopPlayback(clearCurrent: true) }
        model.playQueueItem(fixture.entries[0].id)
        // This remains in VLC's stopped state: the preparation task cannot run until we yield.
        model.pausePlayback()
        model.selectCenterPage(.home)

        model.togglePlayback()

        XCTAssertEqual(model.centerPage, .home)
        XCTAssertEqual(model.currentQueueID, fixture.entries[0].id)
    }

    func testRadioPauseResumeUsesContinuationEvenThoughItReopensTheStream() {
        for useToggle in [false, true] {
            let model = AppModel(preferences: AppPreferences(), registerSystemControls: false)
            let source = SourceRecord(id: RadioLibrary.sourceID, kind: .radio, name: "Radio", location: "")
            model.sources = [source]
            let entry = QueueItem(track: TrackRecord(id: "station", sourceID: source.id, title: "Station"))
            model.queue = [entry]
            model.currentQueueID = entry.id
            model.player.pauseLive()
            model.selectCenterPage(.home)

            if useToggle { model.togglePlayback() } else { model.resumePlayback() }

            XCTAssertEqual(model.centerPage, .home)
            XCTAssertEqual(model.currentQueueID, entry.id)
            model.stopPlayback(clearCurrent: true)
        }
    }

    func testFailedAcceptedRequestCannotCauseALateSwitchOrRearmLaunchMode() async throws {
        let fixture = makeFixture(mode: .oncePerLaunch)
        let model = fixture.model
        defer { model.stopPlayback(clearCurrent: true) }
        model.playQueueItem(fixture.entries[0].id)
        XCTAssertEqual(model.centerPage, .playing)
        model.selectCenterPage(.home)
        try await eventually { model.message != nil && model.playbackTask == nil }
        XCTAssertEqual(model.centerPage, .home)

        model.playQueueItem(fixture.entries[1].id)
        XCTAssertEqual(model.centerPage, .home)
    }

    func testLocalPreparationPauseResumeAndManualPreparedHandoffRespectNavigation() async throws {
        let fixture = try makeLocalFixture(firstSeconds: 20, secondSeconds: 20)
        let model = fixture.model
        defer { model.stopPlayback(clearCurrent: true); try? FileManager.default.removeItem(at: fixture.root) }
        await model.start()
        model.add(fixture.tracks)
        let entries = model.queue
        model.contextMode = .lyrics
        model.contextTab = "Tags"

        model.playQueueItem(entries[0].id)
        XCTAssertEqual(model.centerPage, .playing)
        model.selectCenterPage(.home)
        model.selectHomeFilter(.mostPlayed)
        try await eventually { model.player.state == .playing && model.player.position > 0.05 }
        XCTAssertEqual(model.centerPage, .home, "Asynchronous preparation must not perform another navigation.")
        try await eventually { model.playbackDiagnostics.events.contains { $0.kind == .upcomingPrepared } }

        model.pausePlayback()
        try await eventually { model.player.state == .paused }
        model.resumePlayback()
        try await eventually { model.player.state == .playing }
        XCTAssertEqual(model.centerPage, .home)
        model.togglePlayback()
        try await eventually { model.player.state == .paused }
        model.togglePlayback()
        try await eventually { model.player.state == .playing }
        XCTAssertEqual(model.centerPage, .home)

        model.playQueueItem(entries[1].id)

        XCTAssertEqual(model.currentQueueID, entries[1].id)
        XCTAssertEqual(model.centerPage, .playing)
        XCTAssertTrue(model.playbackDiagnostics.events.contains { $0.kind == .nativeHandoff }, "This must exercise the prepared-player fast path.")
        XCTAssertEqual(model.contextMode, .lyrics)
        XCTAssertEqual(model.contextTab, "Tags")
        XCTAssertEqual(model.homeFilter, .mostPlayed)
        model.stopPlayback(clearCurrent: true)
        await model.finishPlaybackAccess()
    }

    func testAutomaticPreparedSuccessorKeepsHomeAndItsFilter() async throws {
        let fixture = try makeLocalFixture(firstSeconds: 3, secondSeconds: 8)
        let model = fixture.model
        defer { model.stopPlayback(clearCurrent: true); try? FileManager.default.removeItem(at: fixture.root) }
        await model.start()
        model.add(fixture.tracks, play: true)
        let entries = model.queue
        XCTAssertEqual(model.centerPage, .playing)
        model.selectCenterPage(.home)
        model.selectHomeFilter(.recentlyPlayed)
        try await eventually { model.playbackDiagnostics.events.contains { $0.kind == .upcomingPrepared } }

        try await eventually { model.currentQueueID == entries[1].id && model.player.state == .playing && model.player.position > 0.05 }

        XCTAssertEqual(model.centerPage, .home)
        XCTAssertEqual(model.homeFilter, .recentlyPlayed)
        XCTAssertTrue(model.playbackDiagnostics.events.contains { $0.kind == .nativeHandoff })
        model.stopPlayback(clearCurrent: true)
        await model.finishPlaybackAccess()
    }

    private func makeFixture(mode: PlayingAutoSwitchMode = .manualTrackStart) -> (model: AppModel, entries: [QueueItem]) {
        var preferences = AppPreferences()
        preferences.playingAutoSwitchMode = mode
        let model = AppModel(preferences: preferences, registerSystemControls: false)
        let entries = [QueueItem(track: track("a")), QueueItem(track: track("b")), QueueItem(track: track("c"))]
        model.queue = entries
        return (model, entries)
    }

    private func track(_ id: String) -> TrackRecord {
        TrackRecord(id: id, sourceID: "source-a", title: "Track \(id)", artist: "Artist", album: "Album", duration: 180)
    }

    private func makeLocalFixture(firstSeconds: Int, secondSeconds: Int) throws -> (model: AppModel, root: URL, tracks: [TrackRecord]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokPlayingNavigation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.wav"), second = root.appendingPathComponent("second.wav")
        try wave(seconds: firstSeconds).write(to: first)
        try wave(seconds: secondSeconds).write(to: second)
        let source = SourceRecord(id: "local", kind: .local, name: "Local", location: root.absoluteString)
        let tracks = [
            TrackRecord(id: "local-a", sourceID: source.id, title: "First", duration: Double(firstSeconds), fileURL: first.absoluteString),
            TrackRecord(id: "local-b", sourceID: source.id, title: "Second", duration: Double(secondSeconds), fileURL: second.absoluteString)
        ]
        let store = try LibraryStore(url: root.appendingPathComponent("library.sqlite"))
        try store.saveSource(source)
        try store.upsertTracks(tracks)
        var preferences = AppPreferences(); preferences.volume = 0
        let model = AppModel(store: store, preferences: preferences, registerSystemControls: false)
        return (model, root, tracks)
    }

    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected playback state did not arrive.", file: file, line: line)
        throw Timeout.playback
    }

    private enum Timeout: Error { case playback }

    private func wave(seconds: Int) -> Data {
        let size = seconds * 8_000 * 2
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); word(UInt32(size + 36)); data.append(contentsOf: "WAVEfmt ".utf8)
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(8_000)); word(UInt32(16_000))
        word(UInt16(2)); word(UInt16(16)); data.append(contentsOf: "data".utf8); word(UInt32(size)); data.append(Data(count: size))
        return data
    }
}
