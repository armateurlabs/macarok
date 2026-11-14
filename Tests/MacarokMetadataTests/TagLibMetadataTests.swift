import Foundation
import MacarokCore
@testable import MacarokMetadata
import XCTest

final class TagLibMetadataTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokMetadataTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testWritesOnlyRequestedTagsAndPreservesAudioAndUnknownProperties() throws {
        let file = directory.appendingPathComponent("fixture.flac")
        try flacFixture.write(to: file)
        let originalFrames = try flacFrames(Data(contentsOf: file))
        try TagLibMetadataService.write(properties: ["TITLE": "Original", "ARTIST": "Artist", "MACAROK_TEST_CUSTOM": "Preserve me"], to: file)
        let updated = try TagLibMetadataService.write(properties: ["TITLE": "Revised", "ALBUM": "Test Album", "DATE": "2026"], to: file)
        XCTAssertEqual(updated.title, "Revised")
        XCTAssertEqual(updated.artist, "Artist")
        XCTAssertEqual(updated.year, 2026)
        XCTAssertEqual(try TagLibMetadataService.properties(url: file)["MACAROK_TEST_CUSTOM"], ["Preserve me"])
        XCTAssertEqual(try flacFrames(Data(contentsOf: file)), originalFrames)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["fixture.flac"])
    }

    func testEmbeddedArtworkRoundTripAndInvalidArtworkPreservesOriginal() throws {
        let file = directory.appendingPathComponent("fixture.flac")
        try flacFixture.write(to: file)
        let image = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j2foAAAAASUVORK5CYII="))
        let updated = try TagLibMetadataService.write(properties: [:], artworkData: image, artworkMIMEType: "image/png", to: file)
        XCTAssertEqual(updated.artworkData, image)
        XCTAssertEqual(updated.artworkMIMEType, "image/png")
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try TagLibMetadataService.write(properties: ["TITLE": "Should not be written"], artworkData: Data("not an image".utf8), to: file))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testNativeFLACCUESheetRetainsNonCDSamplePrecision() throws {
        let file = directory.appendingPathComponent("album.flac")
        try flacWithNativeCUE().write(to: file)
        let metadata = try TagLibMetadataService.read(url: file)
        let points = try XCTUnwrap(metadata.cuePoints)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[1].startSample, 1_234)
        XCTAssertEqual(points[1].endSample, 8_000)
        XCTAssertEqual(points[1].sampleRate, 8_000)
        try TagLibMetadataService.write(properties: ["ALBUM": "Preserved CUE"], to: file)
        XCTAssertEqual(try TagLibMetadataService.read(url: file).cuePoints, points)
        try TagLibMetadataService.write(properties: ["MACAROK_CUE_TRACK_02_TITLE": "Second", "MACAROK_CUE_TRACK_02_ARTIST": "Guest"], to: file)
        let edited = try XCTUnwrap(TagLibMetadataService.read(url: file).cuePoints)
        XCTAssertEqual(edited[1].startSample, 1_234)
        XCTAssertEqual(edited[1].title, "Second")
        XCTAssertEqual(edited[1].artist, "Guest")
    }

    func testCUEEditPreservesOtherTracksIndexesAndComments() throws {
        let text = """
        REM COMMENT "Keep this comment"
        PERFORMER "Album Artist"
        TITLE "Album"
        FILE "album.flac" WAVE
          TRACK 01 AUDIO
            TITLE "First"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Second"
            INDEX 00 03:59:00
            INDEX 01 04:01:12
        """
        let result = try TagLibMetadataService.updatedCUEText(text, trackNumber: 2, title: "Second (Edited)", artist: "Guest", album: "Album (Remastered)", albumArtist: "New Album Artist")
        let parsed = try CUEParser.parse(result)
        XCTAssertEqual(parsed.title, "Album (Remastered)")
        XCTAssertEqual(parsed.performer, "New Album Artist")
        XCTAssertEqual(parsed.tracks[0].title, "First")
        XCTAssertEqual(parsed.tracks[0].performer, "Album Artist")
        XCTAssertEqual(parsed.tracks[1].title, "Second (Edited)")
        XCTAssertEqual(parsed.tracks[1].performer, "Guest")
        XCTAssertTrue(result.contains("REM COMMENT \"Keep this comment\""))
        XCTAssertTrue(result.contains("INDEX 00 03:59:00"))
        XCTAssertTrue(result.contains("INDEX 01 04:01:12"))
        XCTAssertThrowsError(try TagLibMetadataService.updatedCUEText(text, trackNumber: 2, title: "Bad\nFILE \"other.flac\" WAVE"))
    }

    func testCUEFileWritingPreservesCRLFAndQuotedTitles() throws {
        let file = directory.appendingPathComponent("album.cue")
        let text = "TITLE \"Album\"\r\nFILE \"album.flac\" WAVE\r\n  TRACK 01 AUDIO\r\n    TITLE \"Original\"\r\n    INDEX 01 00:00:00\r\n"
        try Data(text.utf8).write(to: file)
        try TagLibMetadataService.writeCUETrack(cueURL: file, trackNumber: 1, title: "A \"Quoted\" Title")
        let updated = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(updated.contains("\r\n"))
        XCTAssertEqual(try CUEParser.parse(updated).tracks[0].title, "A \"Quoted\" Title")
    }

    func testAddingCUEAlbumArtistPreservesArtistsInheritedFromMultipleFiles() throws {
        let text = """
        TITLE "Album"
        FILE "first.flac" WAVE
          TRACK 01 AUDIO
            TITLE "First"
            INDEX 01 00:00:00
        FILE "second.flac" WAVE
          TRACK 02 AUDIO
            TITLE "Second"
            INDEX 01 00:00:00
        """
        let result = try TagLibMetadataService.updatedCUEText(text, trackNumber: 1,
            albumArtist: "Various Artists", fallbackTrackArtists: [1: "First Artist", 2: "Second Artist"])
        let sheet = try CUEParser.parse(result)
        XCTAssertEqual(sheet.performer, "Various Artists")
        XCTAssertEqual(sheet.tracks.map(\.performer), ["First Artist", "Second Artist"])
        XCTAssertEqual(sheet.tracks.map(\.fileName), ["first.flac", "second.flac"])
        XCTAssertEqual(sheet.tracks.map(\.index01.frames), [0, 0])
    }

    func testTextEmbeddedCUECanBeUpdatedWithoutChangingSharedAlbumTags() throws {
        let file = directory.appendingPathComponent("album.flac")
        try flacFixture.write(to: file)
        let cue = "FILE \"album.flac\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"Old\"\n    INDEX 01 00:00:00\n"
        try TagLibMetadataService.write(properties: ["CUESHEET": cue, "ALBUM": "Shared album"], to: file)
        let edited = try TagLibMetadataService.writeEmbeddedCUETrack(audioURL: file, trackNumber: 1, title: "New")
        XCTAssertEqual(edited.album, "Shared album")
        XCTAssertEqual(try CUEParser.parse(XCTUnwrap(edited.embeddedCueSheet)).tracks[0].title, "New")
    }

    private var flacFixture: Data {
        Data(base64Encoded: "ZkxhQwAAACICAAIAAAALAAANAfQA8AAAH0Ae4Bk2cWCcfWPP6JuSCtMThAAADgYAAABmZm1wZWcAAAAA//iUCAAgAAAA/Vv/+JQIAScAAACRI//4lAgCLgAAACWr//iUCAMpAAAASdP/+JQIBDwAAADMvv/4lAgFOwAAAKDG//iUCAYyAAAAFE7/+JQIBzUAAAB4Nv/4lAgIGAAAAJ6R//iUCAkfAAAA8un/+JQIChYAAABGYf/4lAgLEQAAACoZ//iUCAwEAAAAr3T/+JQIDQMAAADDDP/4lAgOCgAAAHeE//h0CA8BP3oAAABeNA==")!
    }

    private func flacFrames(_ data: Data) throws -> Data {
        var offset = 4
        while offset + 4 <= data.count {
            let isLast = data[offset] & 0x80 != 0
            let size = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            offset += 4 + size
            if isLast { return data.suffix(from: offset) }
        }
        throw MetadataError.unsupported("Invalid test fixture")
    }

    private func flacWithNativeCUE() throws -> Data {
        var original = flacFixture
        var offset = 4
        while true {
            let last = original[offset] & 0x80 != 0
            let size = Int(original[offset + 1]) << 16 | Int(original[offset + 2]) << 8 | Int(original[offset + 3])
            if last {
                original[offset] &= 0x7F
                offset += 4 + size
                break
            }
            offset += 4 + size
        }
        var cue = Data(repeating: 0, count: 396)
        cue[395] = 3
        for (number, sample) in [(1, UInt64(0)), (2, UInt64(1_234)), (255, UInt64(8_000))] {
            var track = Data(repeating: 0, count: 36)
            var bigEndian = sample.bigEndian
            withUnsafeBytes(of: &bigEndian) { track.replaceSubrange(0..<8, with: $0) }
            track[8] = UInt8(number)
            track[35] = number == 255 ? 0 : 1
            cue.append(track)
            if number != 255 {
                var index = Data(repeating: 0, count: 12)
                index[8] = 1
                cue.append(index)
            }
        }
        var block = Data([0x85, UInt8(cue.count >> 16 & 0xFF), UInt8(cue.count >> 8 & 0xFF), UInt8(cue.count & 0xFF)])
        block.append(cue)
        original.insert(contentsOf: block, at: offset)
        return original
    }
}
