import Foundation
import KeyboardShortcuts
import MacarokCore
import XCTest
@testable import MacarokApp

/// Controller checks use temporary indexes and never open media or register system controls.
@MainActor
final class AppModelTests: XCTestCase {
    func testSourceSwitchSeparatesSearchGroupingAndHomeAndClearsSelection() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model
        await model.start()
        model.sourceID = fixture.local.id

        await expectEventually { model.snapshotSourceID == fixture.local.id && !model.isLoadingLibrary }

        XCTAssertEqual(Set(model.tracks.map(\.id)), Set(fixture.localTracks.map(\.id)))
        XCTAssertEqual(model.albums.count, 2)
        XCTAssertEqual(Set(model.artists.map(\.name)), ["Meridian Atlas", "Paper Satellites"])
        model.search = "signal"
        await expectEventually { model.displayedTracks.map(\.id) == [fixture.localTracks[0].id] }
        model.inspect(fixture.localTracks[0])
        model.selectedFolder = "Rock"

        model.sourceID = fixture.remote.id
        XCTAssertEqual(model.search, "")
        XCTAssertNil(model.selectedFolder)
        XCTAssertNil(model.selectedTrackID)
        XCTAssertNil(model.selectedAlbumID)
        XCTAssertNil(model.selectedArtist)
        XCTAssertTrue(model.tracks.isEmpty, "Switching sources must immediately hide the previous catalog.")
        await expectEventually { model.snapshotSourceID == fixture.remote.id && !model.isLoadingLibrary }
        XCTAssertEqual(Set(model.tracks.map(\.id)), Set(fixture.remoteTracks.map(\.id)))
        XCTAssertEqual(model.visibleAlbums.map(\.title), ["Cloud Album"])
        XCTAssertEqual(model.artists.map(\.name), ["Remote Artist"])
        XCTAssertEqual(model.recentlyAdded.map(\.id), ["remote-cloud"])
        XCTAssertEqual(model.recentlyPlayed.map(\.id), [fixture.remoteTracks[0].id])
        XCTAssertEqual(model.mostPlayedTracks.map(\.id), [fixture.remoteTracks[0].id])
        XCTAssertEqual(model.mostPlayedAlbums.map(\.id), ["remote-cloud"])
        XCTAssertEqual(model.mostPlayedArtists.map(\.name), ["Remote Artist"])

        model.search = "signal"
        await expectEventually { model.displayedTracks.map(\.id) == [fixture.remoteTracks[0].id] }
        XCTAssertEqual(model.visibleAlbums.map(\.title), ["Cloud Album"])
    }

    func testChangingSourceDuringDebounceCannotPublishOldSearchResults() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model
        await model.start()
        model.sourceID = fixture.local.id
        model.search = "paper"
        model.sourceID = fixture.remote.id
        model.search = "signal"

        await expectEventually { model.searchResults.map(\.id) == [fixture.remoteTracks[0].id] }
        XCTAssertEqual(model.sourceID, fixture.remote.id)
        XCTAssertTrue(model.displayedTracks.allSatisfy { $0.sourceID == fixture.remote.id })
    }

    func testDefaultDoubleClickAppendsAndKeepsCurrentQueueIdentity() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model
        await model.start()
        model.sourceID = fixture.local.id
        model.add([fixture.localTracks[0]])
        let currentID = try XCTUnwrap(model.queue.first?.id)
        model.currentQueueID = currentID

        model.doubleClick(fixture.localTracks[1])
        model.add([fixture.remoteTracks[0]])

        XCTAssertFalse(model.settings.doubleClickPlays)
        XCTAssertEqual(model.currentQueueID, currentID)
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertEqual(model.currentTrack?.id, fixture.localTracks[0].id)
        XCTAssertEqual(model.queue.map(\.track.id), [fixture.localTracks[0].id, fixture.localTracks[1].id, fixture.remoteTracks[0].id])
        XCTAssertEqual(model.sourceID, fixture.local.id)
        XCTAssertEqual(model.player.state, .stopped)
        XCTAssertNil(model.message)
    }

    func testDuplicateTracksHaveIndependentQueueEntryIdentity() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model
        await model.start()
        model.add([fixture.localTracks[0], fixture.localTracks[0], fixture.localTracks[0]])
        XCTAssertEqual(model.queue.count, 3)
        XCTAssertEqual(Set(model.queue.map(\.id)).count, 3)
        XCTAssertEqual(Set(model.queue.map(\.track.id)), [fixture.localTracks[0].id])
        let secondID = model.queue[1].id
        model.currentQueueID = secondID

        model.removeQueue(IndexSet(integer: 0))

        XCTAssertEqual(model.currentQueueID, secondID)
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertEqual(model.queue.count, 2)
        await model.flushQueue()
        XCTAssertEqual(try fixture.store.loadQueue()?.trackIDs, [fixture.localTracks[0].id, fixture.localTracks[0].id])
    }

    func testMoveRemoveAndShufflePreserveCurrentEntryUntilItIsRemoved() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model
        await model.start()
        model.add([fixture.localTracks[0], fixture.localTracks[1], fixture.localTracks[0], fixture.remoteTracks[0]])
        let originalIDs = model.queue.map(\.id)
        let currentID = originalIDs[2]
        model.currentQueueID = currentID
        model.selectedQueueID = currentID

        model.moveQueue(from: IndexSet(integer: 0), to: 4)
        XCTAssertEqual(model.queue.map(\.id), [originalIDs[1], originalIDs[2], originalIDs[3], originalIDs[0]])
        XCTAssertEqual(model.currentQueueID, currentID)
        XCTAssertEqual(model.currentIndex, 1)
        model.removeQueue(IndexSet(integer: 0))
        XCTAssertEqual(model.currentQueueID, currentID)
        XCTAssertEqual(model.currentIndex, 0)
        let remainingIDs = Set(model.queue.map(\.id))

        model.shuffleQueue()
        XCTAssertEqual(Set(model.queue.map(\.id)), remainingIDs)
        XCTAssertEqual(model.currentQueueID, currentID)
        XCTAssertEqual(model.selectedQueueID, currentID)
        XCTAssertEqual(model.queue.first?.id, currentID)
        await model.flushQueue()
        XCTAssertEqual(try fixture.store.loadQueue()?.trackIDs, model.queue.map(\.track.id))
        XCTAssertEqual(try fixture.store.loadQueue()?.currentIndex, 0)

        model.removeQueue(IndexSet(integer: 0))
        XCTAssertNil(model.currentQueueID)
        XCTAssertNil(model.currentTrack)
        XCTAssertFalse(model.queue.contains { $0.id == currentID })
        XCTAssertEqual(model.player.state, .stopped)
    }

    func testRepeatButtonCyclesThroughAllThreeModes() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model
        await model.start()
        XCTAssertEqual(model.settings.repeatMode, .none)
        model.cycleRepeat()
        XCTAssertEqual(model.settings.repeatMode, .playlist)
        XCTAssertEqual(model.settings.repeatMode.symbol, "repeat")
        model.cycleRepeat()
        XCTAssertEqual(model.settings.repeatMode, .track)
        XCTAssertEqual(model.settings.repeatMode.symbol, "repeat.1")
        model.cycleRepeat()
        XCTAssertEqual(model.settings.repeatMode, .none)
    }

    func testSavedQueueRestoresDuplicateSelectionAndPositionWithoutStartingPlayback() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let ids = [fixture.localTracks[0].id, fixture.remoteTracks[0].id, fixture.localTracks[0].id]
        try fixture.store.saveQueue(trackIDs: ids, currentIndex: 2, position: 37.25)
        let model = fixture.model
        await model.start()

        XCTAssertEqual(model.queue.map(\.track.id), ids)
        XCTAssertEqual(Set(model.queue.map(\.id)).count, 3)
        XCTAssertEqual(model.currentIndex, 2)
        XCTAssertEqual(model.currentTrack?.id, fixture.localTracks[0].id)
        XCTAssertEqual(model.player.state, .stopped)
        let entryIDs = model.queue.map(\.id)
        await model.start()
        XCTAssertEqual(model.queue.map(\.id), entryIDs, "Repeated start must not replace queue entry identities.")

        model.add([fixture.localTracks[1]])
        await model.flushQueue()
        let saved = try XCTUnwrap(fixture.store.loadQueue())
        XCTAssertEqual(saved.trackIDs, ids + [fixture.localTracks[1].id])
        XCTAssertEqual(saved.currentIndex, 2)
        XCTAssertEqual(saved.position, 37.25, accuracy: 0.000_001)
    }

    func testUnavailableAppendDoesNotRemoveExistingQueue() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model
        await model.start()
        model.add([fixture.localTracks[0]])
        let original = model.queue
        var missing = fixture.localTracks[1]
        missing.isAvailable = false

        model.add([missing])

        XCTAssertEqual(model.queue, original)
        XCTAssertEqual(model.message?.title, "Tracks unavailable")
    }

    func testRestorationKeepsOriginalQueuePositionWhenEarlierEntriesWereDeleted() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try fixture.store.saveQueue(trackIDs: ["deleted-track", fixture.localTracks[0].id, fixture.remoteTracks[0].id], currentIndex: 1, position: 23)
        await fixture.model.start()
        XCTAssertEqual(fixture.model.currentTrack?.id, fixture.localTracks[0].id)
        XCTAssertEqual(fixture.model.currentIndex, 0)
        fixture.model.saveQueue()
        await fixture.model.flushQueue()
        XCTAssertEqual(try fixture.store.loadQueue()?.position, 23)
    }

    func testMissingCurrentEntryDoesNotApplyItsSavedPositionToAnotherTrack() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try fixture.store.saveQueue(trackIDs: [fixture.localTracks[0].id, "deleted-current", fixture.remoteTracks[0].id], currentIndex: 1, position: 23)
        await fixture.model.start()
        XCTAssertEqual(fixture.model.currentTrack?.id, fixture.remoteTracks[0].id)
        fixture.model.saveQueue()
        await fixture.model.flushQueue()
        XCTAssertEqual(try fixture.store.loadQueue()?.position, 0)
    }

    func testClearingQueueCancelsPlaybackBeforeItsTaskStarts() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        await fixture.model.start()
        fixture.model.add([fixture.localTracks[0]], play: true)
        fixture.model.clearQueue()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(fixture.model.queue.isEmpty)
        XCTAssertNil(fixture.model.currentTrack)
        XCTAssertEqual(fixture.model.player.state, .stopped)
        XCTAssertNil(fixture.model.message, "A cancelled playback task must not report a missing-file error after clearing.")
    }

    func testOlderCancelledRefreshCannotFinishNewRefresh() async throws {
        let gate = ScanGate()
        let fixture = try makeFixture(localScan: { source, progress in
            await gate.enter()
            return try await LibraryScanner().scan(source: source, metadataReader: { _ in AudioFileMetadata() }, progress: progress)
        })
        defer { fixture.removeFiles() }
        await fixture.model.start()
        fixture.model.sourceID = fixture.local.id
        fixture.model.refresh()
        let firstStarted = await gate.waitForCalls(1)
        XCTAssertTrue(firstStarted)
        fixture.model.refresh()
        let secondStarted = await gate.waitForCalls(2)
        XCTAssertTrue(secondStarted)
        await gate.release(0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fixture.model.isRefreshing)
        XCTAssertNotEqual(fixture.model.status, "Refresh cancelled.")
        await gate.release(1)
        await expectEventually { !fixture.model.isRefreshing }
    }

    func testFolderChangeDuringRefreshSchedulesAnotherScan() async throws {
        let gate = ScanGate()
        let fixture = try makeFixture(localScan: { source, progress in
            await gate.enter()
            return try await LibraryScanner().scan(source: source, metadataReader: { _ in AudioFileMetadata() }, progress: progress)
        })
        defer { fixture.removeFiles() }
        await fixture.model.start()
        fixture.model.sourceID = fixture.local.id
        fixture.model.refresh()
        let firstStarted = await gate.waitForCalls(1)
        XCTAssertTrue(firstStarted)
        fixture.model.requestRescan(sourceID: fixture.local.id)
        await gate.release(0)
        let followUpStarted = await gate.waitForCalls(2)
        XCTAssertTrue(followUpStarted)
        XCTAssertTrue(fixture.model.isRefreshing)
        await gate.release(1)
        await expectEventually { !fixture.model.isRefreshing }
    }

    func testDisabledShortcutDiffersFromDefaultAndCanBeRestored() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model
        await model.start()
        XCTAssertEqual(model.localShortcut("playPause"), KeyboardShortcuts.Shortcut(.space))
        XCTAssertNil(model.menuShortcut("playPause"), "An unmodified space must remain available to text editing.")
        model.settings.localShortcuts["playPause"] = Data("null".utf8)
        XCTAssertNil(model.localShortcut("playPause"), "An explicitly disabled shortcut must not fall back to its default.")

        let custom = KeyboardShortcuts.Shortcut(.p, modifiers: [.command, .option])
        model.settings.localShortcuts["playPause"] = try JSONEncoder().encode(custom)
        XCTAssertEqual(model.localShortcut("playPause"), custom)
        XCTAssertNotNil(model.menuShortcut("playPause"))
        model.settings.localShortcuts.removeValue(forKey: "playPause")
        XCTAssertEqual(model.localShortcut("playPause"), KeyboardShortcuts.Shortcut(.space))
    }

    func testFolderSelectionIncludesDescendantsAndExcludesPrefixSiblings() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model
        await model.start()
        model.sourceID = fixture.local.id

        XCTAssertEqual(model.folderPath(fixture.localTracks[0]), "Rock/Live")
        XCTAssertEqual(Set(model.tracksInFolder("Rock").map(\.id)), Set(fixture.localTracks.prefix(2).map(\.id)))
        XCTAssertEqual(model.tracksInFolder("Rock/Live").map(\.id), [fixture.localTracks[0].id])
        XCTAssertEqual(model.tracksInFolder("Rockabilly").map(\.id), [fixture.localTracks[2].id])
        XCTAssertEqual(model.tracksInFolder("").count, 3)
        model.selectedFolder = "Rock"
        XCTAssertEqual(Set(model.folderTracks.map(\.id)), Set(fixture.localTracks.prefix(2).map(\.id)))

        model.sourceID = fixture.remote.id
        await expectEventually { model.snapshotSourceID == fixture.remote.id && !model.isLoadingLibrary }
        XCTAssertEqual(model.folderPath(fixture.remoteTracks[0]), "Remote/Cloud")
        XCTAssertEqual(model.tracksInFolder("Remote").count, 2)
        XCTAssertTrue(model.tracksInFolder("Rock").isEmpty)
    }

    private func expectEventually(file: StaticString = #filePath, line: UInt = #line,
                                  _ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The controller did not publish the expected state within two seconds.", file: file, line: line)
    }

    private func makeFixture(localScan: LocalScanOperation? = nil) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokAppTests-\(UUID().uuidString)", isDirectory: true)
        let music = directory.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let store = try LibraryStore(url: directory.appendingPathComponent("test.sqlite"))
        let local = SourceRecord(id: "local", kind: .local, name: "Macarok Demo Local", location: music.absoluteString,
                                 createdAt: Date(timeIntervalSince1970: 1))
        let remote = SourceRecord(id: "remote", kind: .openSubsonic, name: "Macarok Demo Remote", location: "https://music.invalid",
                                  createdAt: Date(timeIntervalSince1970: 2))
        let played = Date(timeIntervalSince1970: 1_000)
        let localTracks = [
            TrackRecord(id: "local-signal", sourceID: local.id, albumID: "local-afterlight", title: "Signal Fire", artist: "Meridian Atlas", album: "Afterlight", year: 2005, genre: "Rock", duration: 120,
                        fileURL: music.appendingPathComponent("Rock/Live/01.flac").absoluteString, format: "FLAC", lastPlayedAt: played, playCount: 7),
            TrackRecord(id: "local-paper", sourceID: local.id, albumID: "local-field-notes", title: "Paper Boat", artist: "Paper Satellites", album: "Field Notes", year: 2013, genre: "Ambient", duration: 180,
                        fileURL: music.appendingPathComponent("Rock/Studio/02.flac").absoluteString, format: "FLAC"),
            TrackRecord(id: "local-sibling", sourceID: local.id, albumID: "local-afterlight", title: "Sibling", artist: "Meridian Atlas", album: "Afterlight", year: 2005, genre: "Rock", duration: 90,
                        fileURL: music.appendingPathComponent("Rockabilly/03.flac").absoluteString, format: "FLAC")
        ]
        let remoteTracks = [
            TrackRecord(id: "remote-signal", sourceID: remote.id, albumID: "remote-cloud", title: "Signal Fire", artist: "Remote Artist", album: "Cloud Album", year: 2026, duration: 130,
                        remoteID: "song-1", remotePath: "Remote/Cloud/01.flac", format: "FLAC", lastPlayedAt: played, playCount: 12),
            TrackRecord(id: "remote-second", sourceID: remote.id, albumID: "remote-cloud", title: "Second Cloud", artist: "Remote Artist", album: "Cloud Album", year: 2026, duration: 150,
                        remoteID: "song-2", remotePath: "Remote/Cloud/02.flac", format: "FLAC")
        ]
        try store.saveSource(local)
        try store.saveSource(remote)
        try store.upsertTracks(localTracks + remoteTracks)
        var preferences = AppPreferences()
        preferences.volume = 0
        let model: AppModel
        if let localScan { model = AppModel(store: store, preferences: preferences, registerSystemControls: false, localScan: localScan) }
        else { model = AppModel(store: store, preferences: preferences, registerSystemControls: false) }
        return Fixture(directory: directory, store: store, model: model, local: local, remote: remote,
                       localTracks: localTracks, remoteTracks: remoteTracks)
    }

    private struct Fixture {
        var directory: URL
        var store: LibraryStore
        var model: AppModel
        var local: SourceRecord
        var remote: SourceRecord
        var localTracks: [TrackRecord]
        var remoteTracks: [TrackRecord]

        func removeFiles() { try? FileManager.default.removeItem(at: directory) }
    }
}

private actor ScanGate {
    private var continuations: [CheckedContinuation<Void, Never>?] = []
    func enter() async { await withCheckedContinuation { continuations.append($0) } }
    func release(_ index: Int) { if continuations.indices.contains(index) { continuations[index]?.resume(); continuations[index] = nil } }
    func waitForCalls(_ count: Int) async -> Bool {
        for _ in 0..<100 {
            if continuations.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
