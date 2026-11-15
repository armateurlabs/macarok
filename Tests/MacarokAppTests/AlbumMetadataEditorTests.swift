import Foundation
import MacarokCore
import MacarokMetadata
import XCTest
@testable import MacarokApp

@MainActor
final class AlbumMetadataEditorTests: XCTestCase {
    func testDraftChangesOnlySharedFieldsAndKeepsConcurrentTrackSpecificMetadata() {
        let original = TrackRecord(id: "song", sourceID: "source", title: "Original title", artist: "Original artist", album: "Original album",
            year: 2000, genre: "Rock", trackNumber: 2, discNumber: 1, duration: 180,
            artworkPath: "/old.jpg", cuePath: "/album.cue", startTime: 10, endTime: 190)
        let session = AlbumMetadataEditingSession(track: original)
        session.draft.album = "Corrected album"
        session.draft.genre = "Jazz"
        var latest = original
        latest.title = "Concurrent title"
        latest.artist = "Concurrent artist"
        latest.year = 2001
        latest.trackNumber = 3
        latest.discNumber = 2
        latest.artworkPath = "/new.jpg"
        latest.playCount = 7
        latest.lastPlayedAt = Date(timeIntervalSince1970: 1_000)
        let merged = AlbumMetadataDraft.applying(session.properties, to: latest)
        XCTAssertEqual(session.properties, ["ALBUM": "Corrected album", "GENRE": "Jazz"])
        XCTAssertEqual(merged.album, "Corrected album")
        XCTAssertEqual(merged.genre, "Jazz")
        XCTAssertEqual(merged.title, latest.title)
        XCTAssertEqual(merged.artist, latest.artist)
        XCTAssertEqual(merged.year, latest.year)
        XCTAssertEqual(merged.trackNumber, latest.trackNumber)
        XCTAssertEqual(merged.discNumber, latest.discNumber)
        XCTAssertEqual(merged.startTime, latest.startTime)
        XCTAssertEqual(merged.endTime, latest.endTime)
        XCTAssertEqual(merged.artworkPath, latest.artworkPath)
        XCTAssertEqual(merged.playCount, latest.playCount)
        XCTAssertEqual(merged.lastPlayedAt, latest.lastPlayedAt)
    }

    func testRemoteAlbumUsesCompleteActualSourceSelectionAndPreservesQueueIdentities() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let first = SourceRecord(id: "first", kind: .openSubsonic, name: "First", location: "https://first.invalid")
        let other = SourceRecord(id: "other", kind: .openSubsonic, name: "Other", location: "https://other.invalid")
        try store.saveSource(first); try store.saveSource(other)
        let one = TrackRecord(id: "one", sourceID: first.id, albumID: "raw-album", title: "Visible match", artist: "Artist One", albumArtist: "Various", album: "Original", trackNumber: 1, discNumber: 1, duration: 180)
        let two = TrackRecord(id: "two", sourceID: first.id, albumID: "raw-album", title: "Hidden sibling", artist: "Artist Two", albumArtist: "Various", album: "Original", trackNumber: 2, discNumber: 1, duration: 181)
        let copy = TrackRecord(id: "copy", sourceID: other.id, albumID: "raw-album", title: "Other copy", artist: "Artist", album: "Original", duration: 180)
        try store.upsertTracks([one, two, copy])
        let savedCopy = try XCTUnwrap(store.track(id: copy.id))
        let model = AppModel(store: store, preferences: AppPreferences(), registerSystemControls: false)
        await model.start()
        model.libraryScope = .all
        model.search = "Visible match"
        model.add([one, two, one])
        let queueIDs = model.queue.map(\.id)
        let session = AlbumMetadataEditingSession(track: one)
        await model.loadAlbumMetadata(session: session)
        XCTAssertEqual(Set(session.tracks.map(\.id)), [one.id, two.id])
        XCTAssertTrue(session.hasMixedArtists)
        session.draft.album = "Corrected"
        session.draft.genre = "Jazz"
        var concurrent = two
        concurrent.title = "Concurrent title"
        concurrent.year = 1999
        concurrent.artworkPath = "/new-cover.jpg"
        try store.updateTrackMetadata(concurrent)
        try store.recordPlay(trackID: two.id, at: Date(timeIntervalSince1970: 1_000))
        try await model.applyAlbumMetadataEdits(session: session)
        await model.waitForLibraryLoad()
        let savedOne = try XCTUnwrap(store.track(id: one.id)), savedTwo = try XCTUnwrap(store.track(id: two.id))
        XCTAssertEqual(savedOne.album, "Corrected")
        XCTAssertEqual(savedTwo.album, "Corrected")
        XCTAssertEqual(savedOne.albumID, savedTwo.albumID)
        XCTAssertEqual(savedOne.artist, one.artist)
        XCTAssertEqual(savedTwo.artist, two.artist)
        XCTAssertEqual(savedTwo.title, "Concurrent title")
        XCTAssertEqual(savedTwo.year, 1999)
        XCTAssertEqual(savedTwo.artworkPath, "/new-cover.jpg")
        XCTAssertEqual(savedTwo.playCount, 1)
        XCTAssertEqual(savedTwo.trackNumber, 2)
        XCTAssertTrue(savedOne.metadataLocked)
        XCTAssertEqual(try store.track(id: copy.id), savedCopy)
        XCTAssertEqual(model.queue.map(\.id), queueIDs)
        XCTAssertEqual(model.queue.filter { $0.track.id == one.id }.map(\.track.album), ["Corrected", "Corrected"])
    }

    func testLocalAlbumWritesAllFilesPreservingTitlesNumbersAudioAndUnrelatedTags() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let music = directory.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let files = [music.appendingPathComponent("01.flac"), music.appendingPathComponent("02.flac")]
        var audio: [URL: Data] = [:]
        for (index, file) in files.enumerated() {
            try flacFixture.write(to: file)
            try TagLibMetadataService.write(properties: ["TITLE": "Title \(index + 1)", "ALBUM": "Original", "ARTIST": "Artist \(index + 1)", "ALBUMARTIST": "Various", "TRACKNUMBER": String(index + 1), "DISCNUMBER": "2", "COMMENT": "Keep unknown \(index)"], to: file)
            audio[file] = try flacFrames(Data(contentsOf: file))
        }
        let source = SourceRecord(id: "local", kind: .local, name: "Music", location: music.absoluteString)
        let scanner = LibraryScanner(artworkCacheURL: directory.appendingPathComponent("Artwork"))
        let scanned = try await scanner.scan(source: source, metadataReader: { try TagLibMetadataService.read(url: $0) })
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try store.saveSource(source); try store.upsertTracks(scanned.tracks)
        let model = AppModel(store: store, preferences: AppPreferences(), registerSystemControls: false)
        await model.start()
        let session = AlbumMetadataEditingSession(track: try XCTUnwrap(scanned.tracks.first))
        session.draft.album = "Updated album"
        session.draft.albumArtist = "Album Artist"
        session.draft.year = "2026"
        session.draft.genre = "Jazz"
        session.protectValues = false
        try await model.applyAlbumMetadataEdits(session: session)
        await model.waitForLibraryLoad()
        for (index, file) in files.enumerated() {
            let tags = try TagLibMetadataService.properties(url: file)
            XCTAssertEqual(tags["ALBUM"]?.first, "Updated album")
            XCTAssertEqual(tags["ALBUMARTIST"]?.first, "Album Artist")
            XCTAssertEqual(tags["ARTIST"]?.first, "Artist \(index + 1)")
            XCTAssertEqual(tags["TITLE"]?.first, "Title \(index + 1)")
            XCTAssertEqual(tags["TRACKNUMBER"]?.first, String(index + 1))
            XCTAssertEqual(tags["DISCNUMBER"]?.first, "2")
            XCTAssertEqual(tags["COMMENT"]?.first, "Keep unknown \(index)")
            XCTAssertEqual(try flacFrames(Data(contentsOf: file)), audio[file])
        }
        let rescanned = try await scanner.scan(source: source, metadataReader: { try TagLibMetadataService.read(url: $0) })
        let saved = try store.tracks(sourceID: source.id)
        XCTAssertEqual(Set(saved.map(\.albumID)).count, 1)
        XCTAssertTrue(saved.allSatisfy { !$0.metadataLocked })
        for track in rescanned.tracks {
            let indexed = try XCTUnwrap(saved.first { $0.id == track.id })
            XCTAssertEqual(track.albumID, indexed.albumID)
            XCTAssertEqual(track.title, indexed.title)
            XCTAssertEqual(track.artist, indexed.artist)
        }
    }

    func testExternalCUEAlbumEditsPreservePerTrackArtistsAndBoundariesAfterUnlockedRescan() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("Album.flac"), cue = directory.appendingPathComponent("Album.cue")
        try flacFixture.write(to: audio)
        try TagLibMetadataService.write(properties: ["ALBUM": "Original", "ARTIST": "Original Artist", "ALBUMARTIST": "Original Artist", "COMMENT": "Keep me"], to: audio)
        try """
            REM COMMENT "Keep cue directive"
            TITLE "Original"
            PERFORMER "Original Artist"
            FILE "Album.flac" WAVE
              TRACK 01 AUDIO
                TITLE "First title"
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                TITLE "Second title"
                PERFORMER "Guest Artist"
                INDEX 01 00:00:10
            """.write(to: cue, atomically: true, encoding: .utf8)
        let source = SourceRecord(id: "cue", kind: .local, name: "CUE", location: directory.absoluteString)
        let scanner = LibraryScanner(artworkCacheURL: directory.appendingPathComponent("Artwork"))
        let scanned = try await scanner.scan(source: source, metadataReader: { try TagLibMetadataService.read(url: $0) })
        XCTAssertEqual(scanned.tracks.count, 2)
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try store.saveSource(source); try store.upsertTracks(scanned.tracks)
        let model = AppModel(store: store, preferences: AppPreferences(), registerSystemControls: false)
        await model.start()
        let session = AlbumMetadataEditingSession(track: try XCTUnwrap(scanned.tracks.first))
        session.draft.album = "Updated"
        session.draft.albumArtist = "Various Artists"
        session.draft.year = "2026"
        session.protectValues = false
        try await model.applyAlbumMetadataEdits(session: session)
        let rescanned = try await scanner.scan(source: source, metadataReader: { try TagLibMetadataService.read(url: $0) })
        XCTAssertEqual(rescanned.tracks.map(\.title), ["First title", "Second title"])
        XCTAssertEqual(rescanned.tracks.map(\.artist), ["Original Artist", "Guest Artist"])
        XCTAssertEqual(rescanned.tracks.map(\.startTime), scanned.tracks.map(\.startTime))
        XCTAssertEqual(rescanned.tracks.map(\.endTime), scanned.tracks.map(\.endTime))
        XCTAssertEqual(Set(rescanned.tracks.map(\.album)), ["Updated"])
        XCTAssertEqual(Set(rescanned.tracks.map(\.albumArtist)), ["Various Artists"])
        XCTAssertTrue(try String(contentsOf: cue, encoding: .utf8).contains("Keep cue directive"))
        XCTAssertEqual(try TagLibMetadataService.properties(url: audio)["COMMENT"]?.first, "Keep me")
        let saved = try store.tracks(sourceID: source.id)
        XCTAssertEqual(Set(saved.map(\.albumID)), Set(rescanned.tracks.map(\.albumID)))
    }

    func testEmbeddedCUEAlbumWritesOnePhysicalFileAndRetainsAudioAndTrackNames() throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("Album.flac")
        try flacFixture.write(to: audio)
        let cue = "TITLE \"Original\"\nPERFORMER \"Original Artist\"\nFILE \"Album.flac\" WAVE\nTRACK 01 AUDIO\nTITLE \"First\"\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nTITLE \"Second\"\nINDEX 01 00:00:10\n"
        try TagLibMetadataService.write(properties: ["CUESHEET": cue, "ALBUM": "Original", "ARTIST": "Original Artist", "COMMENT": "Keep me"], to: audio)
        let originalFrames = try flacFrames(Data(contentsOf: audio))
        let tracks = [1, 2].map { number in
            TrackRecord(id: "cue-\(number)", sourceID: "source", albumID: "album", title: "Preserved \(number)", artist: "Original Artist",
                album: "Original", trackNumber: number, duration: 0.1, fileURL: audio.absoluteString, startTime: number == 1 ? 0 : 10.0 / 75)
        }
        let written = try AlbumMetadataFileWriter.write(properties: ["ALBUM": "New album", "ARTIST": "Unified Artist"], tracks: tracks)
        XCTAssertEqual(written, [audio])
        let properties = try TagLibMetadataService.properties(url: audio)
        let savedSheet = try CUEParser.parse(XCTUnwrap(properties["CUESHEET"]?.first))
        XCTAssertEqual(savedSheet.title, "New album")
        XCTAssertEqual(savedSheet.tracks.map(\.title), ["First", "Second"])
        XCTAssertEqual(savedSheet.tracks.map(\.performer), ["Unified Artist", "Unified Artist"])
        XCTAssertEqual(savedSheet.tracks.map { $0.index01.seconds }, [0, 10.0 / 75])
        XCTAssertEqual(properties["COMMENT"]?.first, "Keep me")
        XCTAssertEqual(try flacFrames(Data(contentsOf: audio)), originalFrames)
    }

    func testPartialFileFailureReportsCompletedDestinationsAndLeavesUnrelatedBytesIntact() throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("a.flac"), bad = directory.appendingPathComponent("z.flac")
        try flacFixture.write(to: good)
        let originalBad = Data([1, 2, 3])
        try originalBad.write(to: bad)
        let tracks = [good, bad].map { TrackRecord(sourceID: "source", fileURL: $0.absoluteString) }
        XCTAssertThrowsError(try AlbumMetadataFileWriter.write(properties: ["ALBUM": "Updated"], tracks: tracks)) { error in
            XCTAssertTrue(error.localizedDescription.contains("1 file already contains these changes"))
        }
        XCTAssertEqual(try TagLibMetadataService.properties(url: good)["ALBUM"]?.first, "Updated")
        XCTAssertEqual(try Data(contentsOf: bad), originalBad)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokAlbumEditor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func flacFrames(_ data: Data) throws -> Data {
        XCTAssertTrue(data.starts(with: Data("fLaC".utf8)))
        var offset = 4
        while offset + 4 <= data.count {
            let last = data[offset] & 0x80 != 0
            let count = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            offset += count + 4
            guard offset <= data.count else { throw CocoaError(.fileReadCorruptFile) }
            if last { return data.subdata(in: offset..<data.count) }
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    private var flacFixture: Data {
        Data(base64Encoded: "ZkxhQwAAACICAAIAAAALAAANAfQA8AAAH0Ae4Bk2cWCcfWPP6JuSCtMThAAADgYAAABmZm1wZWcAAAAA//iUCAAgAAAA/Vv/+JQIAScAAACRI//4lAgCLgAAACWr//iUCAMpAAAASdP/+JQIBDwAAADMvv/4lAgFOwAAAKDG//iUCAYyAAAAFE7/+JQIBzUAAAB4Nv/4lAgIGAAAAJ6R//iUCAkfAAAA8un/+JQIChYAAABGYf/4lAgLEQAAACoZ//iUCAwEAAAAr3T/+JQIDQMAAADDDP/4lAgOCgAAAHeE//h0CA8BP3oAAABeNA==")!
    }
}
