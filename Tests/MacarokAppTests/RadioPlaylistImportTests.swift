import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

@MainActor
final class RadioPlaylistImportTests: XCTestCase {
    func testExportImportAndSavedPlaylistsPreserveLiveStationsDuplicatesAndSingleUndo() async throws {
        for format in [PlaylistFileFormat.m3u, .pls] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokRadioPlaylist-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let originalStore = try LibraryStore(url: directory.appendingPathComponent("original.sqlite"))
            let station = RadioStationRecord(name: "Synthetic Radio", streamURL: "https://radio.invalid/live", directoryID: UUID().uuidString)
            try originalStore.saveRadioStation(station, favorite: true)
            let original = AppModel(store: originalStore, registerSystemControls: false)
            await original.start()
            original.queue = [QueueItem(track: station.track), QueueItem(track: station.track)]
            let entries = original.currentPlaylistEntries()
            XCTAssertTrue(entries.allSatisfy(\.isLiveRadio))
            let file = directory.appendingPathComponent("radio.\(format.rawValue)")
            try PlaylistIO.write(entries: entries, to: file)
            let importedStore = try LibraryStore(url: directory.appendingPathComponent("imported.sqlite"))
            let imported = AppModel(store: importedStore, registerSystemControls: false)
            await imported.start()
            imported.importPlaylist(file)
            try await eventually { imported.queue.count == 2 || imported.message != nil }
            XCTAssertNil(imported.message)
            XCTAssertEqual(imported.queue.map(\.track.id), [station.id, station.id])
            XCTAssertEqual(Set(imported.queue.map(\.id)).count, 2)
            XCTAssertEqual(imported.queue.map(\.track.sourceID), [RadioLibrary.sourceID, RadioLibrary.sourceID])
            XCTAssertEqual(try importedStore.sources().first?.kind, .radio)
            XCTAssertNotNil(try importedStore.radioStation(id: station.id))
            XCTAssertTrue(imported.albums.isEmpty)
            XCTAssertEqual(imported.player.state, .stopped)
            imported.queueUndoManager.undo()
            XCTAssertTrue(imported.queue.isEmpty)
            XCTAssertFalse(imported.queueUndoManager.canUndo, "Import adds the complete playlist as one queue edit.")
            imported.queueUndoManager.redo()
            let playlist = try importedStore.savePlaylist(name: "Live Favorites", trackIDs: imported.queue.map(\.track.id))
            imported.clearQueue()
            imported.loadSavedPlaylist(playlist)
            try await eventually { imported.queue.count == 2 || imported.message != nil }
            imported.currentQueueID = imported.queue.first?.id
            XCTAssertTrue(imported.currentIsRadio)
            XCTAssertEqual(try importedStore.playlistTracks(id: playlist.id).map(\.id), [station.id, station.id])
            imported.stopPlayback(clearCurrent: true)
            await imported.flushQueue()
        }
    }

    func testImportCannotOverwriteAnExistingMusicTrackWithARadioMarker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokRadioCollision-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let source = SourceRecord(id: "music", kind: .local, name: "Music", location: directory.absoluteString)
        try store.saveSource(source)
        let music = TrackRecord(id: "same-id", sourceID: source.id, title: "Keep My Music")
        try store.upsertTracks([music])
        let entry = PlaylistEntry(url: URL(string: "https://radio.invalid/live")!, title: "Station", trackID: music.id, sourceID: RadioLibrary.sourceID, isLiveRadio: true)
        let file = directory.appendingPathComponent("collision.m3u")
        try PlaylistIO.write(entries: [entry], to: file)
        let model = AppModel(store: store, registerSystemControls: false)
        await model.start()
        model.importPlaylist(file)
        try await eventually { model.queue.count == 1 || model.message != nil }
        XCTAssertNil(model.message)
        XCTAssertEqual(try store.track(id: music.id)?.sourceID, source.id)
        XCTAssertEqual(try store.track(id: music.id)?.title, music.title)
        XCTAssertNotEqual(model.queue.first?.track.id, music.id)
        XCTAssertEqual(model.queue.first?.track.sourceID, RadioLibrary.sourceID)
        if let id = model.queue.first?.track.id { XCTAssertNotNil(try store.radioStation(id: id)) }
        await model.flushQueue()
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<150 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("Playlist import did not finish."); throw URLError(.timedOut)
    }
}
