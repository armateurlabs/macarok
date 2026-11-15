import Foundation
import XCTest
import MacarokCore
@testable import MacarokMetadata

final class LyricsFileServiceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testLyricsRoundTripKeepsUnrelatedTagsAcrossSupportedCodecs() throws {
        for ext in ["mp3", "flac", "ogg", "opus"] {
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("MacarokAudioTests/Fixtures/silence.\(ext)")
            let audio = directory.appendingPathComponent("roundtrip.\(ext)")
            try FileManager.default.copyItem(at: fixture, to: audio)
            try TagLibMetadataService.write(properties: ["TITLE": "Unchanged", "COMMENT": "Retain this"], to: audio)
            let before = try TagLibMetadataService.read(url: audio)
            let track = TrackRecord(sourceID: "local", title: "Unchanged", fileURL: audio.path)
            let document = LRCParser.parse("[offset:200]\n[00:01.200]First\n[00:02.200]Second", source: .manual)
            let saved = try LyricsFileService.write(document: document, track: track)
            XCTAssertEqual(saved.count, 2, ext)
            let properties = try TagLibMetadataService.properties(url: audio)
            XCTAssertEqual(properties["TITLE"]?.first, "Unchanged", ext)
            XCTAssertEqual(properties["COMMENT"]?.first, "Retain this", ext)
            XCTAssertEqual(properties["LYRICS"]?.first, "First\nSecond", ext)
            let loaded = try XCTUnwrap(LyricsFileService.read(track: track))
            XCTAssertEqual(loaded.lines.map(\.startTime), [1, 2], ext)
            let after = try TagLibMetadataService.read(url: audio)
            XCTAssertEqual(after.duration, before.duration, ext)
            // Replacing synchronized content with plain lyrics must not leave stale timings.
            try LyricsFileService.write(document: .init(plainText: "Correction", source: .manual), track: track)
            let corrected = try XCTUnwrap(LyricsFileService.read(track: track))
            XCTAssertEqual(corrected.plainText, "Correction", ext)
            XCTAssertFalse(corrected.isSynced, ext)
        }
    }

    func testSharedCUELyricsAreSlicedOnceAndExportedSeparately() throws {
        let audio = directory.appendingPathComponent("album.flac")
        try Data("audio remains unchanged".utf8).write(to: audio)
        let before = try Data(contentsOf: audio)
        let shared = directory.appendingPathComponent("album.lrc")
        try Data("[offset:200]\n[00:59.200]Before\n[01:01.200]Inside\n[02:00.200]Next track".utf8).write(to: shared)
        let track = TrackRecord(sourceID: "local", title: "Segment", trackNumber: 2, duration: 60,
                                fileURL: audio.path, cuePath: directory.appendingPathComponent("album.cue").path,
                                startTime: 60, endTime: 120)
        let sliced = try XCTUnwrap(LyricsFileService.read(track: track))
        XCTAssertEqual(sliced.lines.map(\.text), ["Inside"])
        XCTAssertEqual(sliced.lines.map(\.startTime), [1])
        let saved = try LyricsFileService.write(document: sliced, track: track)
        XCTAssertEqual(saved.map(\.lastPathComponent), ["album.track-02.lrc"])
        XCTAssertEqual(try Data(contentsOf: audio), before)
        XCTAssertEqual(try LyricsFileService.read(track: track)?.lines.map(\.startTime), [1])
        XCTAssertTrue(try String(contentsOf: shared, encoding: .utf8).contains("Before"))
        try LyricsFileService.write(document: .init(plainText: "Per-track correction", source: .manual), track: track)
        XCTAssertEqual(try LyricsFileService.read(track: track)?.plainText, "Per-track correction")
    }

    func testPlainAlbumLyricsDoNotLeakAcrossCUESegments() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacarokAudioTests/Fixtures/silence.flac")
        let audio = directory.appendingPathComponent("album.flac")
        try FileManager.default.copyItem(at: fixture, to: audio)
        try TagLibMetadataService.write(properties: ["LYRICS": "The entire album"], to: audio)
        let track = TrackRecord(sourceID: "local", fileURL: audio.path, startTime: 30, endTime: 60)
        XCTAssertNil(try LyricsFileService.read(track: track))
    }

    func testSidecarFailureReportsCommittedTagsAndKeepsAudioFrames() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacarokAudioTests/Fixtures/silence.flac")
        let audio = directory.appendingPathComponent("blocked.flac")
        try FileManager.default.copyItem(at: fixture, to: audio)
        let frames = try flacFrames(Data(contentsOf: audio))
        try FileManager.default.createDirectory(at: audio.deletingPathExtension().appendingPathExtension("lrc"), withIntermediateDirectories: true)
        let track = TrackRecord(sourceID: "local", fileURL: audio.path)
        XCTAssertThrowsError(try LyricsFileService.write(document: LRCParser.parse("[00:01]Hello"), track: track)) { error in
            XCTAssertEqual((error as? LyricsFileWriteError)?.savedURLs, [audio])
        }
        XCTAssertEqual(try TagLibMetadataService.properties(url: audio)["LYRICS"]?.first, "Hello")
        XCTAssertEqual(try flacFrames(Data(contentsOf: audio)), frames)
    }

    func testRemoteOriginalCannotBeWritten() {
        let remote = TrackRecord(sourceID: "server", fileURL: "https://example.test/song.flac")
        XCTAssertThrowsError(try LyricsFileService.write(document: .init(plainText: "Lyrics", source: .manual), track: remote))
    }

    private func flacFrames(_ data: Data) throws -> Data {
        var offset = 4
        while offset + 4 <= data.count {
            let last = data[offset] & 0x80 != 0
            let length = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            offset += 4 + length
            if last { return data.suffix(from: offset) }
        }
        throw MetadataError.unsupported("Invalid fixture")
    }
}
