import Foundation
import XCTest
@testable import MacarokCore

final class LibraryScannerTests: XCTestCase {
    func testExternalCUEMakesVirtualTracksWithoutAnExtraAlbumFile() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([0]).write(to: folder.appendingPathComponent("album.flac"))
        try """
            TITLE "An Album"
            PERFORMER "An Artist"
            FILE "album.flac" WAVE
              TRACK 01 AUDIO
                TITLE "First"
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                TITLE "Second"
                INDEX 01 00:01:37
              TRACK 03 AUDIO
                TITLE "Third"
                INDEX 01 00:04:00
            """.write(to: folder.appendingPathComponent("album.cue"), atomically: true, encoding: .utf8)
        let source = SourceRecord(kind: .local, name: "Test", location: folder.path)
        let scanner = LibraryScanner(artworkCacheURL: folder.appendingPathComponent("Artwork"))
        let result = try await scanner.scan(source: source) { _ in
            AudioFileMetadata(title: "Entire album", duration: 6, format: "FLAC")
        }
        XCTAssertEqual(result.tracks.count, 3)
        XCTAssertEqual(result.filesScanned, 1)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.tracks[0].duration, 112.0 / 75, accuracy: 0.000_000_001)
        XCTAssertEqual(result.tracks[1].endTime, 4)
        XCTAssertEqual(result.tracks[2].duration, 2)
        XCTAssertEqual(Set(result.tracks.map(\.fileURL)).count, 1)
        XCTAssertTrue(result.tracks.allSatisfy(\.isCUETrack))
        let repeated = try await scanner.scan(source: source) { _ in AudioFileMetadata(duration: 6, format: "FLAC") }
        XCTAssertEqual(result.tracks.map(\.id), repeated.tracks.map(\.id))
    }

    func testEmbeddedNativeCUEPreservesNonCDSampleOffsetsAndArtwork() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([0]).write(to: folder.appendingPathComponent("album.flac"))
        let source = SourceRecord(kind: .local, name: "Test", location: folder.path)
        let artwork = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
        let result = try await LibraryScanner(artworkCacheURL: folder.appendingPathComponent("Cache")).scan(source: source) { _ in
            AudioFileMetadata(artist: "Artist", album: "Album", duration: 2, artworkData: artwork,
                              artworkMIMEType: "image/png", sampleRate: 96_000,
                              cuePoints: [AudioCuePoint(number: 1, startSample: 0, endSample: 100_001, sampleRate: 96_000),
                                          AudioCuePoint(number: 2, startSample: 100_001, endSample: 192_000, sampleRate: 96_000)])
        }
        XCTAssertEqual(result.tracks.count, 2)
        XCTAssertEqual(try XCTUnwrap(result.tracks[1].startTime), 100_001.0 / 96_000, accuracy: 0.000_000_001)
        XCTAssertEqual(result.tracks[0].endTime, result.tracks[1].startTime)
        let path = try XCTUnwrap(result.tracks[0].artworkPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), artwork)
        XCTAssertEqual(result.tracks[0].artworkPath, result.tracks[1].artworkPath)
    }

    func testMissingMetadataFallsBackToFilenameAndSidecarArtwork() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([0]).write(to: folder.appendingPathComponent("01 - A Song.ogg"))
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("Cover.JPG"))
        let source = SourceRecord(kind: .local, name: "Test", location: folder.path)
        let result = try await LibraryScanner().scan(source: source) { _ in AudioFileMetadata() }
        XCTAssertEqual(result.tracks.first?.title, "A Song")
        XCTAssertEqual(result.tracks.first?.format, "OGG")
        let artworkURL = URL(fileURLWithPath: try XCTUnwrap(result.tracks.first?.artworkPath))
        XCTAssertEqual(artworkURL.resolvingSymlinksInPath(), folder.appendingPathComponent("Cover.JPG").resolvingSymlinksInPath())
    }

    func testExplicitFileSourceDoesNotIndexItsParentDirectory() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let selected = folder.appendingPathComponent("Selected.mp3")
        try Data([0]).write(to: selected)
        try Data([0]).write(to: folder.appendingPathComponent("Not Selected.mp3"))
        let source = SourceRecord(kind: .local, name: "Selected", location: selected.absoluteString)
        let result = try await LibraryScanner().scan(source: source) { _ in AudioFileMetadata(duration: 30) }
        XCTAssertEqual(result.tracks.count, 1)
        XCTAssertEqual(result.tracks[0].url, selected)
    }

    func testExplicitPlaylistSourcePreservesSegmentsWithoutIndexingOtherFiles() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("album.flac")
        try Data([0]).write(to: audio)
        try Data([0]).write(to: folder.appendingPathComponent("unlisted.mp3"))
        let playlist = folder.appendingPathComponent("Parts.m3u8")
        try PlaylistIO.write(entries: [PlaylistEntry(url: audio, title: "First", startTime: 0, endTime: 10),
                                       PlaylistEntry(url: audio, title: "Second", startTime: 10, endTime: 30)], to: playlist)
        let source = SourceRecord(kind: .local, name: "Parts", location: playlist.absoluteString)
        let result = try await LibraryScanner().scan(source: source) { _ in AudioFileMetadata(duration: 30, format: "FLAC") }
        XCTAssertEqual(result.tracks.count, 2)
        XCTAssertEqual(Set(result.tracks.map(\.title)), ["First", "Second"])
        XCTAssertEqual(result.tracks.map(\.startTime).compactMap { $0 }.sorted(), [0, 10])
        XCTAssertEqual(result.tracks.map(\.duration).sorted(), [10, 20])
    }

    func testExplicitPlaylistResolvesAudioSidecarsAndCUEEntriesWithoutScanningParent() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("album.flac")
        let cue = folder.appendingPathComponent("album.cue")
        try Data([0]).write(to: audio)
        try Data([0]).write(to: folder.appendingPathComponent("unlisted.mp3"))
        try """
            TITLE "Continuous Album"
            FILE "album.flac" WAVE
              TRACK 01 AUDIO
                TITLE "First"
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                TITLE "Second"
                INDEX 01 00:01:37
            """.write(to: cue, atomically: true, encoding: .utf8)

        for entry in [audio, cue] {
            let playlist = folder.appendingPathComponent("\(entry.pathExtension).m3u8")
            try PlaylistIO.write(entries: [PlaylistEntry(url: entry)], to: playlist)
            let source = SourceRecord(kind: .local, name: "Playlist", location: playlist.absoluteString)
            let result = try await LibraryScanner().scan(source: source) { _ in AudioFileMetadata(duration: 6, format: "FLAC") }
            XCTAssertTrue(result.isComplete)
            XCTAssertTrue(result.warnings.isEmpty)
            XCTAssertEqual(result.filesScanned, 1)
            XCTAssertEqual(result.tracks.map(\.title), ["First", "Second"])
            XCTAssertTrue(result.tracks.allSatisfy(\.isCUETrack))
            XCTAssertEqual(result.tracks[0].endTime, 112.0 / 75)
            XCTAssertEqual(result.tracks[1].endTime, 6)
        }
    }

    func testBrokenOrUnresolvedCUEPreventsDestructiveScanReconciliation() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([0]).write(to: folder.appendingPathComponent("present.flac"))
        let cue = folder.appendingPathComponent("album.cue")
        let source = SourceRecord(kind: .local, name: "Music", location: folder.absoluteString)
        let sheets = [
            "FILE \"missing.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n",
            "FILE \"present.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 invalid\n"
        ]
        for text in sheets {
            try text.write(to: cue, atomically: true, encoding: .utf8)
            let result = try await LibraryScanner().scan(source: source) { _ in AudioFileMetadata(duration: 6) }
            XCTAssertFalse(result.isComplete, "A temporary CUE failure must retain previously indexed virtual tracks.")
            XCTAssertFalse(result.warnings.isEmpty)
            XCTAssertEqual(result.filesScanned, 1)
        }
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
