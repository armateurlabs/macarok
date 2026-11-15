import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

@MainActor
final class CenterNavigationTests: XCTestCase {
    func testPlayingFollowsQueueChangesWithoutResettingLyricsTagsOrBrowsingScope() {
        let fixture = makeFixture()
        let model = fixture.model
        model.currentQueueID = fixture.entries[0].id
        model.centerPage = .playing
        model.contextMode = .lyrics
        model.contextTab = "Tags"
        model.inspect(fixture.entries[2].track)
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[2].track.id)

        model.currentQueueID = fixture.entries[1].id

        XCTAssertEqual(model.centerPage, .playing)
        XCTAssertTrue(model.contextPage == .track)
        XCTAssertEqual(model.contextMode, .lyrics)
        XCTAssertEqual(model.contextTab, "Tags")
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[1].track.id)
        XCTAssertEqual(model.playingContextTrack?.sourceID, "source-b")
        XCTAssertEqual(model.libraryScope, .source("source-a"), "Following playback must not redirect the library source.")
        XCTAssertEqual(model.player.state, .stopped, "Selecting central views must never start playback.")
    }

    func testHomeKeepsItsFilterWhilePlaybackAdvancesAndPlayingCatchesUpOnReturn() {
        let fixture = makeFixture()
        let model = fixture.model
        model.currentQueueID = fixture.entries[0].id
        model.centerPage = .playing
        model.contextMode = .lyrics
        model.contextTab = "Tags"
        model.homeFilter = .mostPlayed
        model.centerPage = .home

        model.currentQueueID = fixture.entries[1].id

        XCTAssertEqual(model.centerPage, .home)
        XCTAssertEqual(model.homeFilter, .mostPlayed)
        XCTAssertEqual(model.contextMode, .lyrics)
        XCTAssertEqual(model.contextTab, "Tags")
        model.centerPage = .playing
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[1].track.id)
        XCTAssertEqual(model.homeFilter, .mostPlayed)
        XCTAssertEqual(model.contextMode, .lyrics)
        XCTAssertEqual(model.contextTab, "Tags")
    }

    func testChangingLibraryScopeKeepsPlayingContextAndChosenDetailTab() {
        let fixture = makeFixture()
        let model = fixture.model
        model.currentQueueID = fixture.entries[1].id
        model.centerPage = .playing
        model.contextTab = "Tags"

        model.libraryScope = .source("source-a")
        model.libraryScope = .all

        XCTAssertEqual(model.centerPage, .playing)
        XCTAssertTrue(model.contextPage == .track)
        XCTAssertEqual(model.contextTab, "Tags")
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[1].track.id)
        XCTAssertEqual(model.libraryScope, .all)
    }

    func testInlineMetadataSessionPinsItsTargetUntilFinishedThenCatchesUp() throws {
        let fixture = makeFixture()
        let model = fixture.model
        model.currentQueueID = fixture.entries[0].id
        model.centerPage = .playing
        model.contextTab = "Tags"
        model.contextMode = .editMetadata
        let session = try XCTUnwrap(model.metadataEditingSession)
        XCTAssertEqual(session.track.id, fixture.entries[0].track.id)
        session.draft.title = "Pinned title correction"

        model.currentQueueID = fixture.entries[1].id
        model.currentQueueID = fixture.entries[2].id
        model.libraryScope = .all

        XCTAssertTrue(model.metadataEditingSession === session)
        XCTAssertEqual(session.draft.title, "Pinned title correction")
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[0].track.id)
        XCTAssertEqual(model.contextMode, .editMetadata)
        XCTAssertEqual(model.contextTab, "Tags")
        model.finishMetadataEditing()
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[2].track.id)
        XCTAssertEqual(model.contextTab, "Tags")
        XCTAssertFalse(model.metadataEditingSession === session)
    }

    func testMetadataAndArtworkSheetsKeepContextPinnedUntilBothClose() {
        let fixture = makeFixture()
        let model = fixture.model
        model.currentQueueID = fixture.entries[0].id
        model.centerPage = .playing
        model.contextTab = "Tags"
        model.editingTrack = fixture.entries[0].track
        model.artworkTrack = fixture.entries[0].track

        model.currentQueueID = fixture.entries[1].id
        model.libraryScope = .all
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[0].track.id)
        model.editingTrack = nil
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[0].track.id)
        model.artworkTrack = nil
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[1].track.id)
        XCTAssertEqual(model.contextTab, "Tags")
        XCTAssertEqual(model.contextMode, .context)
    }

    func testClearingQueueCannotDiscardTheActiveMetadataSession() throws {
        let fixture = makeFixture()
        let model = fixture.model
        model.currentQueueID = fixture.entries[0].id
        model.centerPage = .playing
        model.contextMode = .editMetadata
        let session = try XCTUnwrap(model.metadataEditingSession)

        model.clearQueue()

        XCTAssertTrue(model.queue.isEmpty)
        XCTAssertNil(model.currentQueueID)
        XCTAssertTrue(model.metadataEditingSession === session)
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[0].track.id)
        XCTAssertEqual(model.contextMode, .editMetadata)
        model.finishMetadataEditing()
        XCTAssertNil(model.playingContextTrack)
        XCTAssertEqual(model.centerPage, .playing)
    }

    func testHomePreservesAnEditorDraftUntilTheUserFinishesEditing() throws {
        let fixture = makeFixture()
        let model = fixture.model
        model.currentQueueID = fixture.entries[0].id
        model.centerPage = .playing
        model.beginMetadataEditing()
        let session = try XCTUnwrap(model.metadataEditingSession)
        session.draft.album = "Unfinished album correction"

        model.centerPage = .home
        model.homeFilter = .recentlyPlayed
        model.currentQueueID = fixture.entries[1].id

        XCTAssertEqual(model.centerPage, .home)
        XCTAssertEqual(model.homeFilter, .recentlyPlayed)
        XCTAssertTrue(model.metadataEditingSession === session)
        XCTAssertEqual(session.draft.album, "Unfinished album correction")
        model.centerPage = .playing
        XCTAssertTrue(model.metadataEditingSession === session)
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[0].track.id)
        model.finishMetadataEditing()
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[1].track.id)
    }

    func testLateEditorCompletionCannotCloseANewerSessionOrOverrideCurrentMenus() throws {
        let fixture = makeFixture()
        let model = fixture.model
        model.currentQueueID = fixture.entries[0].id
        model.centerPage = .playing
        model.beginMetadataEditing()
        let original = try XCTUnwrap(model.metadataEditingSession)
        model.currentQueueID = fixture.entries[1].id
        model.finishMetadataEditing(sessionID: original.id)
        model.beginMetadataEditing()
        let replacement = try XCTUnwrap(model.metadataEditingSession)
        XCTAssertNotEqual(original.id, replacement.id)

        model.contextMode = .lyrics
        model.centerPage = .home
        model.homeFilter = .recentlyAdded
        model.currentQueueID = fixture.entries[2].id
        model.finishMetadataEditing(sessionID: original.id)

        XCTAssertTrue(model.metadataEditingSession === replacement)
        XCTAssertEqual(model.centerPage, .home)
        XCTAssertEqual(model.homeFilter, .recentlyAdded)
        XCTAssertEqual(model.contextMode, .lyrics)
        model.finishMetadataEditing(sessionID: replacement.id)
        XCTAssertNil(model.metadataEditingSession)
        XCTAssertEqual(model.centerPage, .home)
        XCTAssertEqual(model.contextMode, .lyrics)
        model.centerPage = .playing
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[2].track.id)
    }

    func testRadioContextUsesThePinnedOrInspectedTrackRatherThanAnotherPlayingEntry() {
        let fixture = makeFixture()
        let model = fixture.model
        model.sources.append(RadioLibrary.source)
        let station = QueueItem(track: RadioStationRecord(name: "Radio", streamURL: "https://radio.invalid/live").track)
        model.queue.append(station)
        model.currentQueueID = fixture.entries[0].id
        model.centerPage = .playing
        model.contextTab = "Tags"
        model.artworkTrack = fixture.entries[0].track

        model.currentQueueID = station.id

        XCTAssertTrue(model.currentIsRadio)
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[0].track.id)
        XCTAssertFalse(ContextPane(model: model).showsRadioContext, "The pinned music context must remain visible while its artwork editor is open.")
        model.artworkTrack = nil
        XCTAssertTrue(ContextPane(model: model).showsRadioContext, "Closing the editor resumes following the radio entry.")

        model.inspect(fixture.entries[1].track)

        XCTAssertTrue(model.currentIsRadio)
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[1].track.id)
        XCTAssertFalse(ContextPane(model: model).showsRadioContext, "Inspecting music must display its own context even while a station is playing.")
        XCTAssertEqual(model.contextTab, "Tags")

        model.currentQueueID = fixture.entries[0].id
        model.inspect(station.track)
        XCTAssertTrue(ContextPane(model: model).showsRadioContext)
        let inspectedStation = RadioNowPlayingView(model: model, track: model.playingContextTrack)
        XCTAssertEqual(inspectedStation.displayedTrack?.title, "Radio", "A queued station's context must not display the currently playing music title.")
        XCTAssertFalse(inspectedStation.showsCurrentBroadcast, "Broadcast metadata and reconnection controls belong only to the actual current station.")
        model.currentQueueID = station.id
        XCTAssertTrue(RadioNowPlayingView(model: model, track: model.playingContextTrack).showsCurrentBroadcast)
    }

    func testMetadataDraftMergesOnlyEditedFieldsAndPreservesNewerArtworkAndHistory() {
        let original = TrackRecord(id: "edited", sourceID: "source-a", title: "Original title", artist: "Original artist", album: "Original album", duration: 180)
        let session = MetadataEditingSession(track: original)
        session.draft.title = "My title correction"
        session.draft.year = "2026"
        var latest = original
        latest.artist = "Concurrent artist correction"
        latest.album = "Concurrent album correction"
        latest.artworkPath = "/synthetic/new-artwork.png"
        latest.playCount = 12
        latest.lastPlayedAt = Date(timeIntervalSince1970: 1_800_000_000)
        latest.rating = 4

        let merged = session.editedTrack(preserving: latest)

        XCTAssertEqual(merged.id, original.id)
        XCTAssertEqual(merged.sourceID, original.sourceID)
        XCTAssertEqual(merged.title, "My title correction")
        XCTAssertEqual(merged.year, 2026)
        XCTAssertEqual(merged.artist, latest.artist)
        XCTAssertEqual(merged.album, latest.album)
        XCTAssertEqual(merged.artworkPath, latest.artworkPath)
        XCTAssertEqual(merged.playCount, latest.playCount)
        XCTAssertEqual(merged.lastPlayedAt, latest.lastPlayedAt)
        XCTAssertEqual(merged.rating, latest.rating)
        XCTAssertEqual(merged.duration, latest.duration)
    }

    private func makeFixture() -> (model: AppModel, entries: [QueueItem]) {
        let model = AppModel(preferences: AppPreferences(), registerSystemControls: false)
        model.sources = [
            SourceRecord(id: "source-a", kind: .openSubsonic, name: "Source A", location: "https://a.invalid"),
            SourceRecord(id: "source-b", kind: .openSubsonic, name: "Source B", location: "https://b.invalid")
        ]
        model.libraryScope = .source("source-a")
        let entries = [
            QueueItem(track: TrackRecord(id: "track-a", sourceID: "source-a", title: "First", artist: "Artist A", album: "Album A", duration: 180)),
            QueueItem(track: TrackRecord(id: "track-b", sourceID: "source-b", title: "Second", artist: "Artist B", album: "Album B", duration: 180)),
            QueueItem(track: TrackRecord(id: "track-c", sourceID: "source-a", title: "Third", artist: "Artist A", album: "Album A", duration: 180))
        ]
        model.queue = entries
        return (model, entries)
    }
}
