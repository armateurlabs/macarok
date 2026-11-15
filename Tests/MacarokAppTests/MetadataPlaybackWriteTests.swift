import CryptoKit
import Foundation
import MacarokCore
import MacarokMetadata
import XCTest
@testable import MacarokApp

@MainActor
final class MetadataPlaybackWriteTests: XCTestCase {
    func testVerifiedAtomicMetadataSavePreservesLiveAudioAndDuplicateQueueEntries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokPlayingTagWrite-\(UUID().uuidString)")
        let music = directory.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = music.appendingPathComponent("playing.wav")
        try wave(seconds: 12).write(to: audio)
        try TagLibMetadataService.write(properties: ["TITLE": "Original", "ARTIST": "Synthetic Artist", "ALBUM": "Synthetic Album"], to: audio)
        let initialAudio = try audioDigest(audio)
        let source = SourceRecord(id: "playing-tags", kind: .local, name: "Synthetic", location: music.absoluteString)
        let track = TrackRecord(id: "playing-tags-track", sourceID: source.id, title: "Original", artist: "Synthetic Artist",
                                album: "Synthetic Album", duration: 12, fileURL: audio.absoluteString, format: "WAV")
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try store.saveSource(source, tracks: [track])
        let model = AppModel(store: store, preferences: AppPreferences(), registerSystemControls: false)
        await model.start()
        model.player.volume = 0
        defer { model.stopPlayback(clearCurrent: true) }
        model.add([track, track], play: true)
        try await eventually { model.player.state == .playing && model.player.position > 0.2 }
        let before = model.player.position, currentEntry = model.currentQueueID
        let entryIDs = model.queue.map(\.id)
        var edited = track
        edited.title = "Corrected during playback"

        try await model.applyMetadataEdits(original: track, edited: edited, releaseID: nil, lockMetadata: true)
        try await eventually { model.player.position > before + 0.3 }

        XCTAssertEqual(model.player.state, .playing)
        XCTAssertNil(model.player.lastError)
        XCTAssertEqual(model.currentQueueID, currentEntry)
        XCTAssertEqual(model.queue.map(\.id), entryIDs)
        XCTAssertEqual(model.queue.map(\.track.title), [edited.title, edited.title])
        XCTAssertEqual(try TagLibMetadataService.read(url: audio).title, edited.title)
        XCTAssertEqual(try audioDigest(audio), initialAudio, "Metadata replacement must preserve every PCM sample.")
        XCTAssertFalse(LocalFileChangeSuppression.shared.shouldRescan(DirectoryChangeBatch(paths: [audio.path], mustRescan: false)))
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(predicate())
    }

    private func audioDigest(_ url: URL) throws -> Data {
        let bytes = try Data(contentsOf: url)
        var offset = 12
        while offset + 8 <= bytes.count {
            let size = (0..<4).reduce(0) { $0 | Int(bytes[offset + 4 + $1]) << ($1 * 8) }
            guard size >= 0, offset + 8 + size <= bytes.count else { break }
            if bytes[offset..<(offset + 4)] == Data("data".utf8) {
                return Data(SHA256.hash(data: bytes[(offset + 8)..<(offset + 8 + size)]))
            }
            offset += 8 + size + (size % 2)
        }
        XCTFail("The synthetic WAV lost its PCM data chunk.")
        return Data()
    }

    private func wave(seconds: Int) -> Data {
        let rate = 16_000, count = seconds * rate * 2
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + count)); data.append(Data("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(rate)); append(UInt32(rate * 2))
        append(UInt16(2)); append(UInt16(16)); data.append(Data("data".utf8)); append(UInt32(count))
        data.append(Data(repeating: 0, count: count)); return data
    }
}
