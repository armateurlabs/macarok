import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

@MainActor
final class QueueInsertionTests: XCTestCase {
    func testInsertionPreservesDuplicateCurrentEntrySelectionAndRestoredPosition() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        let first = fixture.tracks[0], other = fixture.tracks[1]
        try fixture.store.saveQueue(trackIDs: [first.id, other.id, first.id, other.id], currentIndex: 2, position: 7.25)
        await model.start()
        let original = model.queue
        model.selectedQueueID = original[1].id
        let values = [other, first, other]

        model.addAfterCurrent(values)
        await model.flushQueue()

        XCTAssertEqual(Array(model.queue.prefix(3)), Array(original.prefix(3)))
        XCTAssertEqual(Array(model.queue.suffix(1)), Array(original.suffix(1)))
        XCTAssertEqual(Array(model.queue[3..<6].map(\.track.id)), values.map(\.id))
        XCTAssertEqual(Set(model.queue.map(\.id)).count, model.queue.count, "Duplicate tracks keep distinct queue-entry identities.")
        XCTAssertEqual(model.currentQueueID, original[2].id)
        XCTAssertEqual(model.currentIndex, 2)
        XCTAssertEqual(model.selectedQueueID, original[1].id)
        XCTAssertEqual(model.player.state, .stopped, "Insertion must not autoplay a restored queue.")
        let saved = try XCTUnwrap(fixture.store.loadQueue())
        XCTAssertEqual(saved.trackIDs, [first.id, other.id, first.id, other.id, first.id, other.id, other.id])
        XCTAssertEqual(saved.currentIndex, 2)
        XCTAssertEqual(saved.position, 7.25, accuracy: 0.001)
        XCTAssertNil(model.message)
    }

    func testEmptyOrMissingCurrentEntryAppendsWithoutStartingPlayback() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        await model.start()
        let cases: [([TrackRecord], UUID?)] = [([], nil), ([fixture.tracks[0]], nil), ([fixture.tracks[0]], UUID())]
        for (existing, currentID) in cases {
            model.queue = existing.map { QueueItem(track: $0) }
            model.currentQueueID = currentID
            let originalIDs = model.queue.map(\.id)
            model.addAfterCurrent([fixture.tracks[1], fixture.tracks[1]])
            await model.flushQueue()
            XCTAssertEqual(model.queue.map(\.track.id), existing.map(\.id) + [fixture.tracks[1].id, fixture.tracks[1].id])
            XCTAssertEqual(Array(model.queue.prefix(existing.count).map(\.id)), originalIDs)
            XCTAssertEqual(model.currentQueueID, currentID)
            XCTAssertEqual(model.player.state, .stopped)
            XCTAssertEqual(try fixture.store.loadQueue()?.trackIDs, model.queue.map(\.track.id))
        }
        XCTAssertNil(model.message)
    }

    func testAlbumAndArtistSelectionsRetainTrackOrderAndSourceIdentity() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        await model.start()
        model.queue = [QueueItem(track: fixture.tracks[0]), QueueItem(track: fixture.tracks[1])]
        model.currentQueueID = model.queue[0].id
        let tail = model.queue[1]
        // Both origins reuse a canonical album ID and the same song titles.
        let albumA = AlbumRecord(tracks: Array(fixture.tracks.prefix(2).reversed()))
        let albumB = AlbumRecord(tracks: Array(fixture.tracks.suffix(2).reversed()))
        XCTAssertEqual(albumA.id, albumB.id)
        let orderedArtistSelection = albumA.tracks + albumB.tracks

        model.addAfterCurrent(orderedArtistSelection)
        await model.flushQueue()

        XCTAssertEqual(model.queue[1...4].map(\.track.id), orderedArtistSelection.map(\.id))
        XCTAssertEqual(model.queue[1...4].map(\.track.trackNumber), [1, 2, 1, 2])
        XCTAssertEqual(model.queue[1...4].map(\.track.sourceID), [albumA.sourceID, albumA.sourceID, albumB.sourceID, albumB.sourceID])
        XCTAssertEqual(model.queue.last, tail)
        XCTAssertEqual(model.queue[1...4].map(\.track.albumID), Array(repeating: "shared-album", count: 4))
        XCTAssertEqual(try fixture.store.loadQueue()?.trackIDs, model.queue.map(\.track.id))
        XCTAssertNil(model.message)
    }

    func testEmptyAndUnavailableSelectionsFollowAppendAvailabilityRules() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        await model.start()
        model.queue = [QueueItem(track: fixture.tracks[0])]
        model.currentQueueID = model.queue[0].id
        let original = model.queue
        let originalStatus = model.status
        model.addAfterCurrent([])
        XCTAssertEqual(model.queue, original)
        XCTAssertEqual(model.status, originalStatus)
        XCTAssertNil(model.message)
        var unavailable = fixture.tracks[1]
        unavailable.isAvailable = false
        model.addAfterCurrent([unavailable])
        XCTAssertEqual(model.queue, original)
        XCTAssertEqual(model.message?.title, "Tracks unavailable")
        model.message = nil
        model.addAfterCurrent([unavailable, fixture.tracks[1], unavailable, fixture.tracks[1]])
        XCTAssertEqual(model.queue.map(\.track.id), [fixture.tracks[0].id, fixture.tracks[1].id, fixture.tracks[1].id])
        XCTAssertEqual(model.currentQueueID, original[0].id)
        XCTAssertNil(model.message)
        await model.flushQueue()
    }

    func testInsertionDuringPlaybackKeepsTheExactEntryAndTimelineRunning() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        await model.start()
        model.add([fixture.tracks[0], fixture.tracks[1], fixture.tracks[0], fixture.tracks[1]])
        let current = model.queue[2]
        let tail = model.queue[3]
        model.playQueueItem(current.id)
        try await eventually(model) { model.player.state == .playing && model.player.isSeekable }
        model.player.seek(to: 4)
        try await eventually(model) { model.player.position > 4.1 }
        let position = model.player.position

        model.addAfterCurrent(Array(fixture.tracks.suffix(2)))

        XCTAssertEqual(model.currentQueueID, current.id)
        XCTAssertEqual(model.currentIndex, 2)
        XCTAssertEqual(model.queue[2], current)
        XCTAssertEqual(model.queue.last, tail)
        XCTAssertEqual(model.player.state, .playing)
        XCTAssertEqual(model.player.position, position, accuracy: 0.001)
        try await eventually(model) { model.player.position > position + 0.2 }
        await model.flushQueue()
        let saved = try XCTUnwrap(fixture.store.loadQueue())
        XCTAssertEqual(saved.currentIndex, 2)
        XCTAssertGreaterThan(saved.position, position)
        XCTAssertNil(model.message)
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokQueueInsertion-\(UUID().uuidString)", isDirectory: true)
        let music = directory.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let url = music.appendingPathComponent("silence.wav")
        try silentWave(seconds: 20).write(to: url)
        let a = SourceRecord(id: "queue-source-a", kind: .local, name: "Local", location: music.absoluteString)
        let b = SourceRecord(id: "queue-source-b", kind: .openSubsonic, name: "Remote", location: "https://music.invalid")
        let tracks = [
            TrackRecord(id: "a-1", sourceID: a.id, albumID: "shared-album", title: "Track 1", artist: "Same Artist", album: "Same Album", trackNumber: 1, duration: 20, fileURL: url.absoluteString, format: "WAV"),
            TrackRecord(id: "a-2", sourceID: a.id, albumID: "shared-album", title: "Track 2", artist: "Same Artist", album: "Same Album", trackNumber: 2, duration: 20, fileURL: url.absoluteString, format: "WAV"),
            TrackRecord(id: "b-1", sourceID: b.id, albumID: "shared-album", title: "Track 1", artist: "Same Artist", album: "Same Album", trackNumber: 1, duration: 20, remoteID: "1", format: "FLAC"),
            TrackRecord(id: "b-2", sourceID: b.id, albumID: "shared-album", title: "Track 2", artist: "Same Artist", album: "Same Album", trackNumber: 2, duration: 20, remoteID: "2", format: "FLAC")
        ]
        let store = try LibraryStore(url: directory.appendingPathComponent("test.sqlite"))
        try store.saveSource(a); try store.saveSource(b); try store.upsertTracks(tracks)
        var preferences = AppPreferences(); preferences.volume = 0
        return Fixture(directory: directory, store: store, model: AppModel(store: store, preferences: preferences, registerSystemControls: false), tracks: tracks)
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
        data.append(Data("data".utf8)); append(UInt32(byteCount)); data.append(Data(repeating: 0, count: byteCount))
        return data
    }

    private func eventually(_ model: AppModel, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if condition() { return }
            if model.player.state == .failed || model.message != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Playback did not reach the expected state: \(model.player.state), \(model.message?.detail ?? model.player.lastError ?? "none")")
        throw URLError(.timedOut)
    }

    private struct Fixture {
        let directory: URL
        let store: LibraryStore
        let model: AppModel
        let tracks: [TrackRecord]
        @MainActor func cleanup() {
            model.removeQueue(IndexSet(integersIn: model.queue.indices))
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
