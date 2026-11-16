import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

@MainActor
final class UpcomingPlaybackTests: XCTestCase {
    func testPreparedCUEHandoffKeepsQueueIdentitiesAndPausedClearCannotRestartIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokUpcoming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("album.wav")
        try wave(seconds: 8).write(to: audio)
        let source = SourceRecord(id: "local", kind: .local, name: "Local", location: root.absoluteString)
        let tracks = [
            TrackRecord(id: "first", sourceID: source.id, title: "First", duration: 1.5, fileURL: audio.absoluteString,
                        cuePath: root.appendingPathComponent("album.cue").path, startTime: 0, endTime: 1.5),
            TrackRecord(id: "second", sourceID: source.id, title: "Second", duration: 4, fileURL: audio.absoluteString,
                        cuePath: root.appendingPathComponent("album.cue").path, startTime: 2, endTime: 6)
        ]
        let store = try LibraryStore(url: root.appendingPathComponent("library.sqlite"))
        try store.saveSource(source); try store.upsertTracks(tracks)
        var settings = AppPreferences(); settings.volume = 0
        let model = AppModel(store: store, preferences: settings, registerSystemControls: false)
        await model.start()
        defer { model.stopPlayback(clearCurrent: true) }
        model.add(tracks, play: true)
        let entries = model.queue
        let occurrence = model.playbackGeneration
        try await eventually { model.currentQueueID == entries[1].id && model.player.state == .playing && model.player.position > 0.1 }
        XCTAssertEqual(model.queue, entries)
        XCTAssertNotEqual(model.playbackGeneration, occurrence)
        XCTAssertEqual(model.currentTrack?.id, "second")
        XCTAssertEqual(model.player.duration, 4, accuracy: 0.1)
        XCTAssertLessThan(model.player.position, 4)
        model.pausePlayback()
        try await eventually { model.player.state == .paused }
        model.clearQueue()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.queue.isEmpty)
        XCTAssertNil(model.currentQueueID)
        XCTAssertEqual(model.player.state, .stopped)
        await model.finishPlaybackAccess()
    }

    private func eventually(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The expected playback transition did not arrive.")
    }

    private func wave(seconds: Int) -> Data {
        let size = seconds * 8_000 * 2
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); word(UInt32(size + 36)); data.append(contentsOf: "WAVEfmt ".utf8)
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(8_000)); word(UInt32(16_000))
        word(UInt16(2)); word(UInt16(16)); data.append(contentsOf: "data".utf8); word(UInt32(size)); data.append(Data(count: size))
        return data
    }
}
