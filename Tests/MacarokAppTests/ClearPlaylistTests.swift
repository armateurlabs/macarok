import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

/// Exercises the real player with silent generated media and an isolated library.
@MainActor
final class ClearPlaylistTests: XCTestCase {
    func testClearRetainsExactDuplicateEntryBeforePlaybackStartsAndWhilePlaying() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model
        await model.start()
        model.add([fixture.track, fixture.other, fixture.track, fixture.other])
        let current = model.queue[2]
        model.selectedQueueID = model.queue[1].id
        model.playQueueItem(current.id)

        // The playback task has not run yet; clearing must let that same task finish opening.
        model.clearQueue()

        XCTAssertEqual(model.queue, [current])
        XCTAssertEqual(model.currentQueueID, current.id)
        XCTAssertEqual(model.selectedQueueID, current.id)
        try await eventually(model) { model.player.state == .playing && model.player.isSeekable }
        model.player.seek(to: 4)
        model.add([fixture.other, fixture.track])
        let position = model.player.position

        model.clearQueue()

        XCTAssertEqual(model.queue, [current])
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertEqual(model.player.state, .playing)
        XCTAssertEqual(model.player.position, position, accuracy: 0.001)
        model.queueUndoManager.undo()
        XCTAssertEqual(model.currentQueueID, current.id)
        XCTAssertEqual(model.player.state, .playing)
        model.queueUndoManager.redo()
        XCTAssertEqual(model.queue, [current])
        XCTAssertEqual(model.player.position, position, accuracy: 0.001)
        try await eventually(model) { model.player.position > position + 0.2 }
        await model.flushQueue()
        let saved = try XCTUnwrap(fixture.store.loadQueue())
        XCTAssertEqual(saved.trackIDs, [fixture.track.id])
        XCTAssertEqual(saved.currentIndex, 0)
        XCTAssertGreaterThan(saved.position, position)
        XCTAssertNil(model.message)
    }

    /// Like Apple Music, an entry VLC has not loaded seeks only its start point; Play begins there.
    func testStoppedAndPreparingEntriesSeekTheirResumePoint() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model
        await model.start()
        model.add([fixture.track, fixture.other])
        model.currentQueueID = model.queue[0].id
        XCTAssertEqual(model.player.state, .stopped)
        XCTAssertTrue(model.canSeekCurrent)

        model.seekPlayback(to: 6)
        model.seekWithArrow(keyCode: 124, isRepeat: false)
        XCTAssertEqual(model.restorePosition, 11, accuracy: 0.001)
        XCTAssertEqual(model.displayedPlaybackPosition, 11, accuracy: 0.001)
        XCTAssertEqual(model.player.state, .stopped)
        await model.flushQueue()
        XCTAssertEqual(try XCTUnwrap(fixture.store.loadQueue()).position, 11, accuracy: 0.001)

        model.playQueueItem(model.queue[0].id)
        // The playback task has not opened VLC yet; the new target replaces the parked one.
        model.seekPlayback(to: 14)
        try await eventually(model) { model.player.state == .playing && model.player.position >= 14 }
        XCTAssertLessThan(model.player.position, 17)
        XCTAssertEqual(model.restorePosition, 0)
        XCTAssertNil(model.message)
    }

    func testClearEmptiesPausedQueueAndUndoParksItsResumePosition() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model
        await model.start()
        model.add([fixture.other, fixture.track, fixture.other])
        let current = model.queue[1]
        model.playQueueItem(current.id)
        try await eventually(model) { model.player.state == .playing && model.player.isSeekable }
        model.player.seek(to: 5)
        try await eventually(model) { model.player.position > 5.1 }
        model.player.pause()
        try await eventually(model) { model.player.state == .paused }
        let position = model.player.position
        XCTAssertGreaterThanOrEqual(position, 4.8)

        model.clearQueue()

        XCTAssertTrue(model.queue.isEmpty)
        XCTAssertNil(model.currentQueueID)
        XCTAssertEqual(model.player.state, .stopped)
        model.queueUndoManager.undo()
        XCTAssertEqual(model.queue.count, 3)
        XCTAssertEqual(model.currentQueueID, current.id)
        XCTAssertEqual(model.player.state, .stopped)
        XCTAssertEqual(model.player.position, 0)
        await model.flushQueue()
        let saved = try XCTUnwrap(fixture.store.loadQueue())
        XCTAssertEqual(saved.trackIDs, [fixture.other.id, fixture.track.id, fixture.other.id])
        XCTAssertEqual(saved.currentIndex, 1)
        XCTAssertEqual(saved.position, position, accuracy: 0.001)
        model.togglePlayback()
        try await eventually(model) { model.player.state == .playing && model.player.position > position + 0.2 }
        XCTAssertNil(model.message)
    }

    func testClearEmptiesRestoredQueueAndUndoRestoresItsPositionWithoutAutoplay() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        try fixture.store.saveQueue(trackIDs: [fixture.track.id, fixture.other.id, fixture.track.id],
                                    currentIndex: 2, position: 7.25)
        let model = fixture.model
        await model.start()
        let current = model.queue[2]

        model.clearQueue()
        await model.flushQueue()

        XCTAssertTrue(model.queue.isEmpty)
        XCTAssertNil(model.currentQueueID)
        XCTAssertEqual(model.player.state, .stopped)
        XCTAssertEqual(try fixture.store.loadQueue()?.position, 0)
        model.queueUndoManager.undo()
        await model.flushQueue()
        XCTAssertEqual(model.queue.count, 3)
        XCTAssertEqual(model.currentQueueID, current.id)
        XCTAssertEqual(model.player.state, .stopped)
        let saved = try XCTUnwrap(fixture.store.loadQueue())
        XCTAssertEqual(saved.trackIDs, [fixture.track.id, fixture.other.id, fixture.track.id])
        XCTAssertEqual(saved.currentIndex, 2)
        XCTAssertEqual(saved.position, 7.25, accuracy: 0.001)
    }

    func testClearWithoutAValidCurrentEntryEmptiesQueueAndSelection() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model
        await model.start()
        for currentID in [UUID?.none, UUID()] {
            model.add([fixture.track, fixture.other])
            model.currentQueueID = currentID
            model.selectedQueueID = model.queue.last?.id

            model.clearQueue()
            await model.flushQueue()

            XCTAssertTrue(model.queue.isEmpty)
            XCTAssertNil(model.currentQueueID)
            XCTAssertNil(model.selectedQueueID)
            XCTAssertEqual(model.player.state, .stopped)
            let saved = try XCTUnwrap(fixture.store.loadQueue())
            XCTAssertTrue(saved.trackIDs.isEmpty)
            XCTAssertEqual(saved.position, 0)
        }
    }

    private func eventually(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if condition() { return }
            if model.player.state == .failed || model.message != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Playback did not reach the expected state: \(model.player.state), position: \(model.player.position), error: \(model.message?.detail ?? model.player.lastError ?? "none")",
                file: file, line: line)
        throw PlaybackFailure.timedOut
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokClearPlaylist-\(UUID().uuidString)", isDirectory: true)
        let music = directory.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let url = music.appendingPathComponent("silence.wav")
        try silentWave(seconds: 20).write(to: url)
        let source = SourceRecord(kind: .local, name: "Clear Playlist Test", location: music.absoluteString)
        let track = TrackRecord(id: "silent-current", sourceID: source.id, albumID: "silent-album", title: "Silent Current",
                                artist: "Test Artist", album: "Silent Album", duration: 20, fileURL: url.absoluteString, format: "WAV")
        var other = track
        other.id = "silent-other"
        other.title = "Silent Other"
        let store = try LibraryStore(url: directory.appendingPathComponent("test.sqlite"))
        try store.saveSource(source)
        try store.upsertTracks([track, other])
        var preferences = AppPreferences()
        preferences.volume = 0
        return Fixture(directory: directory, store: store,
                       model: AppModel(store: store, preferences: preferences, registerSystemControls: false),
                       track: track, other: other)
    }

    private func silentWave(seconds: Int) -> Data {
        let sampleRate = 16_000, byteCount = seconds * sampleRate * 2
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + byteCount)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(byteCount))
        data.append(Data(repeating: 0, count: byteCount))
        return data
    }

    private enum PlaybackFailure: Error { case timedOut }

    @MainActor
    private struct Fixture {
        let directory: URL
        let store: LibraryStore
        let model: AppModel
        let track: TrackRecord
        let other: TrackRecord
        func removeFiles() {
            model.removeQueue(IndexSet(integersIn: model.queue.indices))
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
