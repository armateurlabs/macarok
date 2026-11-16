import AppKit
import Foundation
import KeyboardShortcuts
import MacarokCore
import XCTest
@testable import MacarokApp

final class QueuePreferenceTests: XCTestCase {
    func testPodcastIdentityNormalizesRedirectDestinationWithoutDroppingMeaningfulURLComponents() {
        XCTAssertTrue(AppModel.samePodcastFeed("HTTPS://FEEDS.EXAMPLE.COM:443/show.rss#episodes", "https://feeds.example.com/show.rss"))
        XCTAssertTrue(AppModel.samePodcastFeed("https://feeds.example.com", "https://feeds.example.com/"))
        XCTAssertFalse(AppModel.samePodcastFeed("https://feeds.example.com/show?id=1", "https://feeds.example.com/show?id=2"))
        XCTAssertFalse(AppModel.samePodcastFeed("http://feeds.example.com/show", "https://feeds.example.com/show"))
    }

    func testLibrarySortAndAlbumGroupPreferencesPersistAndTolerateLegacyOrUnknownValues() throws {
        let legacy = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"appearance":"dark","volume":0.3}"#.utf8))
        XCTAssertEqual(legacy.librarySortOrder, LibrarySortOrder())
        XCTAssertTrue(legacy.librarySortOrder.isDescending(.years))
        XCTAssertFalse(legacy.playlistAlbumGroups)
        var preferences = AppPreferences()
        preferences.librarySortOrder.toggle(.artists); preferences.librarySortOrder.toggle(.years)
        preferences.playlistAlbumGroups = true
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded.librarySortOrder, preferences.librarySortOrder)
        XCTAssertTrue(decoded.playlistAlbumGroups)
        let future = try JSONDecoder().decode(AppPreferences.self,
            from: Data(#"{"appearance":"light","librarySortOrder":["albums","composers"]}"#.utf8))
        XCTAssertEqual(future.appearance, .light)
        XCTAssertTrue(future.librarySortOrder.isDescending(.albums))
        XCTAssertFalse(future.librarySortOrder.isDescending(.years))
    }

    func testLegacyDoubleClickChoiceMigratesWithoutResettingOtherPreferences() throws {
        let legacy = Data(#"{"doubleClickPlays":true,"appearance":"dark","repeatMode":"track","volume":0.3,"customBuffer":true,"bufferSeconds":42}"#.utf8)
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: legacy)
        XCTAssertEqual(preferences.trackDoubleClickAction, .playNow)
        XCTAssertEqual(preferences.appearance, .dark)
        XCTAssertEqual(preferences.repeatMode, .track)
        XCTAssertEqual(preferences.buffer, 42)
        XCTAssertEqual(preferences.volume, 0.3)
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"doubleClickPlays":false}"#.utf8)).trackDoubleClickAction, .append)
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"trackDoubleClickAction":"afterCurrent","doubleClickPlays":true}"#.utf8)).trackDoubleClickAction, .afterCurrent)
        for action in TrackDoubleClickAction.allCases {
            var value = AppPreferences(); value.trackDoubleClickAction = action
            XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(value)).trackDoubleClickAction, action)
        }
    }

    func testArrowRepeatAccumulatesFromRequestedTargetAndResetsByGenerationAndRelease() {
        var keys = PlaybackArrowKeys()
        let generation = UUID()
        XCTAssertEqual(keys.target(keyCode: 124, isRepeat: false, generation: generation, position: 10, duration: 100), 15)
        XCTAssertEqual(keys.target(keyCode: 124, isRepeat: true, generation: generation, position: 10.1, duration: 100), 20)
        XCTAssertEqual(keys.target(keyCode: 124, isRepeat: true, generation: generation, position: 10.2, duration: 21), 21)
        keys.reset()
        XCTAssertEqual(keys.target(keyCode: 123, isRepeat: false, generation: generation, position: 2, duration: 100), 0)
        XCTAssertNil(keys.target(keyCode: 124, isRepeat: true, generation: UUID(), position: 30, duration: 100))
        XCTAssertTrue(PlaybackArrowKeys.isReserved(keyCode: 124, modifiers: [.function, .numericPad]))
        XCTAssertFalse(PlaybackArrowKeys.isReserved(keyCode: 124, modifiers: .command))
    }
}

@MainActor
final class QueueBehaviorTests: XCTestCase {
    func testEmptyTrackDoubleClickAutoplaysForEveryPreferenceAndGroupsAlwaysAppend() async throws {
        for action in TrackDoubleClickAction.allCases {
            let model = AppModel(registerSystemControls: false)
            model.settings.trackDoubleClickAction = action
            let first = track("first"), second = track("second")
            model.doubleClick(first)
            let current = try XCTUnwrap(model.queue.first?.id)
            XCTAssertEqual(model.currentQueueID, current)
            XCTAssertEqual(model.playbackIntentQueueID, current)
            model.doubleClickSelection([second, first])
            XCTAssertEqual(model.queue.map(\.track.id), [first.id, second.id, first.id])
            XCTAssertEqual(model.currentQueueID, current)
            model.stopPlayback(clearCurrent: true)
        }
    }

    func testTrackAfterCurrentChoiceAndShuffleAppendKeepExistingQueueEntries() {
        let model = AppModel(registerSystemControls: false)
        model.add([track("a"), track("b"), track("c")])
        let original = model.queue
        model.currentQueueID = original[1].id
        model.settings.trackDoubleClickAction = .afterCurrent
        model.doubleClick(track("next"))
        XCTAssertEqual(model.queue.map(\.track.id), ["a", "b", "next", "c"])
        let beforeShuffle = model.queue
        model.shuffle([track("d"), track("e"), track("f")])
        XCTAssertEqual(Array(model.queue.prefix(4)), beforeShuffle)
        XCTAssertEqual(Set(model.queue.suffix(3).map(\.track.id)), ["d", "e", "f"])
        XCTAssertEqual(model.currentQueueID, original[1].id)
        XCTAssertEqual(model.player.state, .stopped)
        model.queueUndoManager.undo()
        XCTAssertEqual(model.queue, beforeShuffle)
        model.queueUndoManager.undo()
        XCTAssertEqual(model.queue, original)
        model.queueUndoManager.redo()
        XCTAssertEqual(model.queue.map(\.track.id), ["a", "b", "next", "c"])
    }

    func testUndoAndRedoRestoreExactDuplicateQueueEntriesAndLatestMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokUndo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("test.sqlite"))
        let source = SourceRecord(id: "source", kind: .openSubsonic, name: "Source", location: "https://music.invalid")
        try store.saveSource(source); try store.upsertTracks([track("a"), track("b")])
        let model = AppModel(store: store, registerSystemControls: false)
        await model.start()
        model.add([track("a"), track("b"), track("a")])
        let original = model.queue
        model.currentQueueID = original[2].id
        model.restorePosition = 7.25
        model.selectedQueueID = original[1].id
        model.removeQueue(IndexSet(integer: 1))
        var edited = track("b"); edited.title = "Updated tags"
        try store.updateTrackMetadata(edited)
        model.reloadLibrary(); await model.waitForLibraryLoad()
        let other = SourceRecord(id: "other", kind: .openSubsonic, name: "Other", location: "https://other.invalid")
        try store.saveSource(other); model.sources.append(other)
        model.libraryScope = .source(other.id); await model.waitForLibraryLoad()
        model.queueUndoManager.undo()
        XCTAssertEqual(model.queue.map(\.id), original.map(\.id))
        XCTAssertEqual(model.queue[1].track.title, "Updated tags")
        XCTAssertEqual(model.selectedQueueID, original[1].id)
        XCTAssertEqual(model.currentQueueID, original[2].id)
        XCTAssertEqual(model.restorePosition, 7.25)
        XCTAssertEqual(model.player.state, .stopped)
        model.queueUndoManager.redo()
        XCTAssertEqual(model.queue.map(\.id), [original[0].id, original[2].id])
        await model.flushQueue()
        XCTAssertEqual(try store.loadQueue()?.trackIDs, ["a", "a"])
        model.sources = []
        XCTAssertFalse(model.queueUndoManager.canUndo)
        XCTAssertFalse(model.queueUndoManager.canRedo)
    }

    func testEveryQueueMutationIsOneUndoableEdit() {
        let model = AppModel(registerSystemControls: false)
        let first = track("a")
        let values = [first, track("b"), first, track("c")]
        model.add(values)
        let original = model.queue
        model.moveQueue(from: IndexSet(integer: 0), to: 4)
        model.queueUndoManager.undo(); XCTAssertEqual(model.queue, original)
        model.shuffleQueue()
        if model.queue != original { model.queueUndoManager.undo(); XCTAssertEqual(model.queue, original) }
        model.clearQueue()
        XCTAssertTrue(model.queue.isEmpty)
        model.queueUndoManager.undo(); XCTAssertEqual(model.queue, original)
        model.queueUndoManager.undo(); XCTAssertTrue(model.queue.isEmpty)
        model.queueUndoManager.redo(); XCTAssertEqual(model.queue, original)
    }

    func testClearThenAddUndoesInOrderAndRestoresParkedResumeWithoutPlayback() {
        let model = AppModel(registerSystemControls: false)
        model.add([track("a"), track("b")])
        let original = model.queue
        model.currentQueueID = original[1].id; model.selectedQueueID = original[0].id; model.restorePosition = 8
        model.clearQueue(); model.add([track("c")])
        model.queueUndoManager.undo()
        XCTAssertTrue(model.queue.isEmpty); XCTAssertNil(model.currentQueueID)
        model.queueUndoManager.undo()
        XCTAssertEqual(model.queue, original)
        XCTAssertEqual(model.currentQueueID, original[1].id)
        XCTAssertEqual(model.selectedQueueID, original[0].id)
        XCTAssertEqual(model.restorePosition, 8)
        XCTAssertEqual(model.player.position, 0)
        XCTAssertEqual(model.player.state, .stopped)
        model.queueUndoManager.redo(); XCTAssertTrue(model.queue.isEmpty)
    }

    func testTimelineAndActivePlaylistSeekWithArrowsWhileOtherControlsKeepThem() {
        _ = NSApplication.shared
        let timeline = BufferedTimelineSlider.makeSlider()
        let playlist = NSTableView(), otherList = NSTableView(), library = NSOutlineView(), field = NSTextView()
        XCTAssertTrue(PlaybackArrowKeys.respondersAllowSeek(from: timeline, until: nil, activePlaylist: playlist))
        XCTAssertTrue(PlaybackArrowKeys.respondersAllowSeek(from: playlist, until: nil, activePlaylist: playlist))
        XCTAssertTrue(PlaybackArrowKeys.respondersAllowSeek(from: NSView(), until: nil, activePlaylist: playlist))
        XCTAssertFalse(PlaybackArrowKeys.respondersAllowSeek(from: playlist, until: nil, activePlaylist: nil))
        XCTAssertFalse(PlaybackArrowKeys.respondersAllowSeek(from: otherList, until: nil, activePlaylist: playlist))
        XCTAssertFalse(PlaybackArrowKeys.respondersAllowSeek(from: library, until: nil, activePlaylist: playlist))
        XCTAssertFalse(PlaybackArrowKeys.respondersAllowSeek(from: field, until: nil, activePlaylist: playlist))
    }

    func testUndoHostKeepsTextUndoSeparateAndRejectsControlArrowNavigation() {
        _ = NSApplication.shared
        let model = AppModel(registerSystemControls: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentView!.bounds)
        window.contentView = content
        let host = QueueUndoHostingView(model: model)
        content.addSubview(host); host.attach()
        defer { host.detach(); window.close() }
        XCTAssertTrue(model.mainPlayerWindow === window)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        editor.allowsUndo = true; content.addSubview(editor)
        XCTAssertFalse(editor.undoManager === model.queueUndoManager, "The field editor must retain native text undo.")
        XCTAssertTrue(model.isReservedArrowShortcut(.init(.leftArrow)))
        XCTAssertFalse(model.isReservedArrowShortcut(.init(.rightArrow, modifiers: .command)))
        XCTAssertFalse(PlaybackArrowKeys.accepts(window: window, mainWindow: nil))
        XCTAssertFalse(PlaybackArrowKeys.accepts(window: nil, mainWindow: window))
    }

    private func track(_ id: String) -> TrackRecord {
        TrackRecord(id: id, sourceID: "source", title: id, artist: "Artist", album: "Album", duration: 20)
    }
}
