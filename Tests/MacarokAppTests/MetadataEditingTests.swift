import Foundation
import MacarokCore
import MacarokMetadata
import XCTest
@testable import MacarokApp

@MainActor
final class MetadataEditingTests: XCTestCase {
    func testLibraryOnlyArtworkForLocalAndRemoteSourcesSurvivesRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokArtworkEditing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("test.sqlite"))
        let local = SourceRecord(id: "artwork-local", kind: .local, name: "Local", location: directory.absoluteString)
        let remote = SourceRecord(id: "artwork-remote", kind: .openSubsonic, name: "Remote", location: "https://music.invalid")
        try store.saveSource(local); try store.saveSource(remote)
        let tracks = [local, remote].map { source in
            TrackRecord(id: "\(source.id)-track", sourceID: source.id, title: "Keep title", artist: "Artist", album: "Album",
                fileURL: source.kind == .local ? directory.appendingPathComponent("unopened.flac").absoluteString : nil)
        }
        try store.upsertTracks(tracks)
        let model = AppModel(store: store, preferences: AppPreferences(), registerSystemControls: false)
        await model.start()
        let image = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j2foAAAAASUVORK5CYII="))
        for track in tracks {
            try await model.saveAlbumArtwork(data: image, for: track, embedInFiles: false, saveSidecar: false)
            let saved = try XCTUnwrap(store.track(id: track.id))
            XCTAssertTrue(saved.metadataLocked)
            let artworkPath = try XCTUnwrap(saved.artworkPath)
            XCTAssertTrue(artworkPath.hasPrefix(directory.path + "/"), "An injected test index must use an isolated artwork cache.")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: artworkPath)), image)
            try store.upsertTracks([track])
            let refreshed = try XCTUnwrap(store.track(id: track.id))
            XCTAssertEqual(refreshed.artworkPath, artworkPath)
            XCTAssertEqual(refreshed.title, "Keep title")
        }
    }

    func testMultiFileCUESharedEditsPersistAcrossFilesAndUnlockedRescan() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokCUEEditing-\(UUID().uuidString)")
        let music = directory.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = [music.appendingPathComponent("first.flac"), music.appendingPathComponent("second.flac")]
        for (index, file) in files.enumerated() {
            try flacFixture.write(to: file)
            try TagLibMetadataService.write(properties: ["ALBUM": "Original", "ARTIST": "Artist \(index + 1)"], to: file)
        }
        let cue = music.appendingPathComponent("album.cue")
        try Data("""
        TITLE "Original"
        FILE "first.flac" WAVE
          TRACK 01 AUDIO
            TITLE "First"
            INDEX 01 00:00:00
        FILE "second.flac" WAVE
          TRACK 02 AUDIO
            TITLE "Second"
            INDEX 01 00:00:00
        """.utf8).write(to: cue)
        let source = SourceRecord(id: "cue-test", kind: .local, name: "CUE test", location: music.absoluteString)
        let scanner = LibraryScanner(artworkCacheURL: directory.appendingPathComponent("Artwork"))
        let scan = try await scanner.scan(source: source, metadataReader: { try TagLibMetadataService.read(url: $0) })
        XCTAssertEqual(scan.tracks.count, 2)
        XCTAssertTrue(scan.warnings.isEmpty)
        let store = try LibraryStore(url: directory.appendingPathComponent("test.sqlite"))
        try store.saveSource(source); try store.upsertTracks(scan.tracks)
        let model = AppModel(store: store, preferences: AppPreferences(), registerSystemControls: false)
        await model.start()
        let original = try XCTUnwrap(scan.tracks.first { $0.trackNumber == 1 })
        var edited = original
        edited.title = "First Edited"; edited.album = "Updated"; edited.albumArtist = "Various Artists"; edited.year = 2026
        try await model.applyMetadataEdits(original: original, edited: edited, releaseID: nil, lockMetadata: false)

        let saved = try store.tracks(sourceID: source.id)
        XCTAssertEqual(Set(saved.map(\.album)), ["Updated"])
        XCTAssertEqual(Set(saved.map(\.albumArtist)), ["Various Artists"])
        XCTAssertEqual(Set(saved.map(\.year)), [2026])
        XCTAssertTrue(saved.allSatisfy { !$0.metadataLocked })
        XCTAssertEqual(Set(saved.map(\.albumID)).count, 1)
        XCTAssertEqual(saved.sorted { $0.trackNumber! < $1.trackNumber! }.map(\.artist), ["Artist 1", "Artist 2"])
        for file in files {
            let metadata = try TagLibMetadataService.read(url: file)
            XCTAssertEqual(metadata.album, "Updated")
            XCTAssertEqual(metadata.albumArtist, "Various Artists")
            XCTAssertEqual(metadata.year, 2026)
        }
        let rescanned = try await scanner.scan(source: source, metadataReader: { try TagLibMetadataService.read(url: $0) })
        XCTAssertTrue(rescanned.warnings.isEmpty)
        for track in rescanned.tracks {
            let previous = try XCTUnwrap(saved.first { $0.id == track.id })
            XCTAssertEqual(track.albumID, previous.albumID)
            XCTAssertEqual(track.title, previous.title)
            XCTAssertEqual(track.artist, previous.artist)
            XCTAssertEqual(track.startTime, previous.startTime)
            XCTAssertEqual(track.endTime, previous.endTime)
        }
    }

    private var flacFixture: Data {
        Data(base64Encoded: "ZkxhQwAAACICAAIAAAALAAANAfQA8AAAH0Ae4Bk2cWCcfWPP6JuSCtMThAAADgYAAABmZm1wZWcAAAAA//iUCAAgAAAA/Vv/+JQIAScAAACRI//4lAgCLgAAACWr//iUCAMpAAAASdP/+JQIBDwAAADMvv/4lAgFOwAAAKDG//iUCAYyAAAAFE7/+JQIBzUAAAB4Nv/4lAgIGAAAAJ6R//iUCAkfAAAA8un/+JQIChYAAABGYf/4lAgLEQAAACoZ//iUCAwEAAAAr3T/+JQIDQMAAADDDP/4lAgOCgAAAHeE//h0CA8BP3oAAABeNA==")!
    }
}
