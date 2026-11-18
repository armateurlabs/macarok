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

    func testLeavingSongEditorResumesPlaybackFollowingAndReturningRestoresItsUnsavedDraft() throws {
        let fixture = makeFixture()
        let model = fixture.model
        model.currentQueueID = fixture.entries[0].id
        model.centerPage = .playing
        model.contextTab = "Tags"
        model.beginMetadataEditing()
        let session = try XCTUnwrap(model.metadataEditingSession)
        session.draft.title = "Unfinished song correction"

        model.currentQueueID = fixture.entries[1].id
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[0].track.id)
        model.contextMode = .context

        XCTAssertFalse(model.isEditingContext, "An inactive stored draft must not keep Playing locked.")
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[1].track.id, "Leaving the editor catches up immediately, without waiting for another queue transition.")
        XCTAssertEqual(model.selectedAlbumID, fixture.entries[1].track.albumID)
        XCTAssertEqual(model.selectedAlbumSourceID, fixture.entries[1].track.sourceID)
        XCTAssertEqual(model.selectedArtist, fixture.entries[1].track.albumArtist)
        XCTAssertEqual(model.contextTab, "Tags")
        for mode in [ContextMode.lyrics, .wikipedia, .context] {
            model.contextMode = mode
            model.currentQueueID = fixture.entries[2].id
            XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[2].track.id)
            XCTAssertEqual(model.contextMode, mode)
            model.currentQueueID = fixture.entries[1].id
            XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[1].track.id)
        }
        XCTAssertTrue(model.metadataEditingSession === session)
        XCTAssertEqual(session.draft.title, "Unfinished song correction")
        model.contextMode = .editMetadata
        XCTAssertTrue(model.isEditingContext)
        XCTAssertTrue(model.metadataEditingSession === session)
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[0].track.id)
        XCTAssertEqual(session.draft.title, "Unfinished song correction")
    }

    func testInactiveAlbumAndSongDraftsPinOnlyTheirOwnVisibleEditors() throws {
        let fixture = makeFixture()
        let model = fixture.model
        model.currentQueueID = fixture.entries[0].id
        model.centerPage = .playing
        model.beginMetadataEditing()
        let songSession = try XCTUnwrap(model.metadataEditingSession)
        songSession.draft.artist = "Song correction"
        model.contextMode = .context
        model.currentQueueID = fixture.entries[1].id
        model.beginAlbumMetadataEditing()
        let albumSession = try XCTUnwrap(model.albumMetadataEditingSession)
        albumSession.draft.album = "Album correction"
        XCTAssertEqual(albumSession.track.id, fixture.entries[1].track.id, "Opening the album editor must use the live target, not an inactive song draft.")
        model.currentQueueID = fixture.entries[2].id
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[1].track.id)
        model.contextMode = .wikipedia
        XCTAssertFalse(model.isEditingContext)
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[2].track.id)
        XCTAssertEqual(WikipediaLookup.query(for: model.playingContextTrack, topic: .album), "Album A Artist A album")
        model.contextMode = .editMetadata
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[0].track.id)
        model.contextMode = .editAlbumMetadata
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[1].track.id)
        XCTAssertTrue(model.metadataEditingSession === songSession)
        XCTAssertTrue(model.albumMetadataEditingSession === albumSession)
        XCTAssertEqual(songSession.draft.artist, "Song correction")
        XCTAssertEqual(albumSession.draft.album, "Album correction")
    }

    func testFreshOtherEditorInheritsTheVisibleEditorsTargetRatherThanPlaybackOrSelection() throws {
        for startsWithAlbum in [false, true] {
            let fixture = makeFixture()
            let model = fixture.model
            model.currentQueueID = fixture.entries[0].id
            model.centerPage = .playing
            if startsWithAlbum { model.beginAlbumMetadataEditing(fixture.entries[1].track) }
            else { model.beginMetadataEditing(fixture.entries[1].track) }
            model.currentQueueID = fixture.entries[2].id
            XCTAssertEqual(model.selectedTrackID, fixture.entries[0].track.id)
            XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[1].track.id)

            model.contextMode = startsWithAlbum ? .editMetadata : .editAlbumMetadata

            XCTAssertEqual(model.metadataEditingSession?.track.id, fixture.entries[1].track.id)
            XCTAssertEqual(model.albumMetadataEditingSession?.track.id, fixture.entries[1].track.id)
            XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[1].track.id)
            XCTAssertEqual(model.currentTrack?.id, fixture.entries[2].track.id)
        }
    }

    func testSwitchingOrdinaryModesPreservesManualInspectionWithInactiveDrafts() throws {
        let fixture = makeFixture()
        let model = fixture.model
        model.currentQueueID = fixture.entries[0].id
        model.centerPage = .playing
        model.beginMetadataEditing()
        let session = try XCTUnwrap(model.metadataEditingSession)
        session.draft.title = "Retained correction"
        model.contextMode = .context
        model.inspect(fixture.entries[1].track)
        model.contextMode = .wikipedia
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[1].track.id)
        XCTAssertEqual(model.lyricsContextTrack?.id, fixture.entries[0].track.id, "Ordinary lyrics retain the queue-following policy.")
        model.contextMode = .lyrics
        model.contextMode = .context
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[1].track.id)
        XCTAssertTrue(model.metadataEditingSession === session)
        XCTAssertEqual(session.draft.title, "Retained correction")
        model.currentQueueID = fixture.entries[2].id
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[2].track.id)
    }

    func testLeavingEditorWithoutAQueueRetainsItsInspectedTargetAndDraft() throws {
        let fixture = makeFixture()
        let model = fixture.model
        model.contextPage = .track
        model.beginMetadataEditing(fixture.entries[1].track)
        let session = try XCTUnwrap(model.metadataEditingSession)
        session.draft.title = "Offline correction"
        model.contextMode = .context
        XCTAssertNil(model.currentTrack)
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[1].track.id)
        XCTAssertTrue(model.metadataEditingSession === session)
        XCTAssertEqual(session.draft.title, "Offline correction")
    }

    func testInactiveSongSaveCompletionPreservesLaterManualTrackAndAlbumInspection() throws {
        for inspectsAlbum in [false, true] {
            let fixture = makeFixture()
            let model = fixture.model
            model.libraryScope = .all
            model.currentQueueID = fixture.entries[0].id
            model.centerPage = .playing
            model.beginMetadataEditing()
            let session = try XCTUnwrap(model.metadataEditingSession)
            session.draft.title = "Saving the original recording"
            model.contextMode = .context
            let inspected = fixture.entries[1].track
            if inspectsAlbum { model.inspectAlbum(containing: inspected) }
            else { model.inspect(inspected) }

            // A Save task can complete after the user leaves the editor and inspects something else.
            model.finishMetadataEditing(sessionID: session.id)

            XCTAssertNil(model.metadataEditingSession)
            XCTAssertEqual(model.contextMode, .context)
            XCTAssertTrue(model.contextPage == (inspectsAlbum ? .album : .track))
            XCTAssertEqual(model.playingContextTrack?.id, inspected.id)
            XCTAssertEqual(model.selectedAlbumID, inspected.albumID)
            XCTAssertEqual(model.selectedAlbumSourceID, inspected.sourceID)
            XCTAssertEqual(model.selectedArtist, inspected.albumArtist)
            XCTAssertEqual(model.currentTrack?.id, fixture.entries[0].track.id)
        }
    }

    func testInactiveAlbumSaveCompletionPreservesLaterManualTrackAndAlbumInspection() throws {
        for inspectsAlbum in [false, true] {
            let fixture = makeFixture()
            let model = fixture.model
            model.libraryScope = .all
            model.currentQueueID = fixture.entries[0].id
            model.centerPage = .playing
            model.beginAlbumMetadataEditing()
            let session = try XCTUnwrap(model.albumMetadataEditingSession)
            session.draft.album = "Saving the original album"
            model.contextMode = .context
            let inspected = fixture.entries[1].track
            if inspectsAlbum { model.inspectAlbum(containing: inspected) }
            else { model.inspect(inspected) }
            model.contextMode = .wikipedia

            model.finishAlbumMetadataEditing(sessionID: session.id)

            XCTAssertNil(model.albumMetadataEditingSession)
            XCTAssertEqual(model.contextMode, .wikipedia)
            XCTAssertTrue(model.contextPage == (inspectsAlbum ? .album : .track))
            XCTAssertEqual(model.playingContextTrack?.id, inspected.id)
            XCTAssertEqual(model.selectedAlbumID, inspected.albumID)
            XCTAssertEqual(model.selectedAlbumSourceID, inspected.sourceID)
            XCTAssertEqual(model.selectedArtist, inspected.albumArtist)
            XCTAssertEqual(model.currentTrack?.id, fixture.entries[0].track.id)
        }
    }

    func testFinishingTheActiveAlbumEditorReleasesItsPinAndCatchesUp() throws {
        let fixture = makeFixture()
        let model = fixture.model
        model.currentQueueID = fixture.entries[0].id
        model.centerPage = .playing
        model.contextTab = "Tags"
        model.beginAlbumMetadataEditing(fixture.entries[1].track)
        let session = try XCTUnwrap(model.albumMetadataEditingSession)
        model.currentQueueID = fixture.entries[2].id
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[1].track.id)

        model.finishAlbumMetadataEditing(sessionID: session.id)

        XCTAssertNil(model.albumMetadataEditingSession)
        XCTAssertFalse(model.isEditingContext)
        XCTAssertEqual(model.contextMode, .context)
        XCTAssertEqual(model.contextTab, "Tags")
        XCTAssertTrue(model.contextPage == .track)
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[2].track.id)
        XCTAssertEqual(model.selectedAlbumSourceID, fixture.entries[2].track.sourceID)
    }

    func testArtworkSheetPinsItsOwnTargetEvenWithAnInactiveMetadataDraft() throws {
        let fixture = makeFixture()
        let model = fixture.model
        model.currentQueueID = fixture.entries[0].id
        model.centerPage = .playing
        model.beginMetadataEditing()
        let session = try XCTUnwrap(model.metadataEditingSession)
        session.draft.album = "Keep this draft"
        model.contextMode = .context
        model.currentQueueID = fixture.entries[1].id
        model.artworkTrack = fixture.entries[1].track
        model.currentQueueID = fixture.entries[2].id
        XCTAssertTrue(model.isEditingContext)
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[1].track.id)
        model.contextMode = .wikipedia
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[1].track.id)
        XCTAssertEqual(model.lyricsContextTrack?.id, fixture.entries[1].track.id)
        model.artworkTrack = nil
        XCTAssertFalse(model.isEditingContext)
        XCTAssertEqual(model.playingContextTrack?.id, fixture.entries[2].track.id)
        XCTAssertEqual(model.lyricsContextTrack?.id, fixture.entries[2].track.id)
        XCTAssertEqual(model.contextMode, .wikipedia)
        XCTAssertTrue(model.metadataEditingSession === session)
        XCTAssertEqual(session.draft.album, "Keep this draft")
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

    func testEmptyingTheQueueReturnsToHomeOnlyWhenPlayingFollowedPlayback() throws {
        let following = makeFixture().model
        following.currentQueueID = following.queue[0].id
        following.centerPage = .playing
        following.contextMode = .lyrics
        following.clearQueue()
        XCTAssertEqual(following.centerPage, .home)
        XCTAssertEqual(following.contextMode, .lyrics, "Returning to Playing later keeps the chosen view.")

        let inspecting = makeFixture()
        inspecting.model.currentQueueID = inspecting.entries[0].id
        inspecting.model.centerPage = .playing
        inspecting.model.inspect(inspecting.entries[2].track)
        inspecting.model.clearQueue()
        XCTAssertEqual(inspecting.model.centerPage, .playing, "A manually inspected track stays in Playing.")

        let removing = makeFixture().model
        removing.currentQueueID = removing.queue[0].id
        removing.centerPage = .playing
        removing.removeQueue(IndexSet(integer: 2)); removing.removeQueue(IndexSet(integer: 1))
        XCTAssertEqual(removing.centerPage, .playing)
        removing.removeQueue(IndexSet(integer: 0))
        XCTAssertEqual(removing.centerPage, .home)
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
