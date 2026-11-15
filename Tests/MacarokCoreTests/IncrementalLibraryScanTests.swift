import Foundation
import GRDB
import XCTest
@testable import MacarokCore

final class IncrementalLibraryScanTests: XCTestCase {
    func testUnchangedMetadataSurvivesReopeningAndOnlyChangedFilesAreRead() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let music = directory.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let first = music.appendingPathComponent("First.flac"), second = music.appendingPathComponent("Second.flac")
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)
        let source = SourceRecord(kind: .local, name: "Music", location: music.absoluteString)
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let scanner = LibraryScanner(artworkCacheURL: directory.appendingPathComponent("Artwork"))
        let original = try await scanner.scan(source: source) { file in
            AudioFileMetadata(title: file.deletingPathExtension().lastPathComponent, artist: "Artist", album: "Album", duration: 30)
        }
        XCTAssertEqual(original.filesRead, 2)
        do {
            let store = try LibraryStore(url: databaseURL)
            try store.saveSource(source)
            try store.replaceSourceTracks(sourceID: source.id, with: original.tracks)
            try store.saveLocalScanCache(sourceID: source.id, entries: original.fileCacheEntries)
        }
        let reopened = try LibraryStore(url: databaseURL)
        let cache = try reopened.localScanCache(sourceID: source.id)
        XCTAssertEqual(cache.count, 2)
        let unchanged = try await scanner.scan(source: source, cachedFiles: cache) { _ in
            XCTFail("An unchanged physical file must not be reopened by TagLib.")
            return AudioFileMetadata()
        }
        XCTAssertEqual(unchanged.filesRead, 0)
        XCTAssertEqual(unchanged.filesScanned, 2)
        XCTAssertEqual(unchanged.tracks.map(\.title), original.tracks.map(\.title))

        // Size changes invalidate the cache even if an external editor preserves the old timestamp.
        let oldDate = try XCTUnwrap(cache[first.path]?.modifiedAt)
        try Data([1, 2, 3]).write(to: first)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: first.path)
        let changed = try await scanner.scan(source: source, cachedFiles: cache) { file in
            XCTAssertEqual(file.lastPathComponent, first.lastPathComponent)
            return AudioFileMetadata(title: "Changed title", artist: "Artist", album: "Album", duration: 31)
        }
        XCTAssertEqual(changed.filesRead, 1)
        XCTAssertTrue(changed.tracks.contains { $0.title == "Changed title" })
        XCTAssertTrue(changed.tracks.contains { $0.title == "Second" })

        // A same-size tag edit is detected by its modification date too.
        let changedCache = Dictionary(uniqueKeysWithValues: changed.fileCacheEntries.map { ($0.path, $0) })
        let secondDate = try XCTUnwrap(changedCache[second.path]?.modifiedAt)
        try FileManager.default.setAttributes([.modificationDate: secondDate.addingTimeInterval(2)], ofItemAtPath: second.path)
        let touched = try await scanner.scan(source: source, cachedFiles: changedCache) { file in
            XCTAssertEqual(file.lastPathComponent, second.lastPathComponent)
            return AudioFileMetadata(title: "Retagged second", duration: 30)
        }
        XCTAssertEqual(touched.filesRead, 1)
        XCTAssertTrue(touched.tracks.contains { $0.title == "Retagged second" })
    }

    func testCUESheetsAndFolderArtworkRefreshWithoutReopeningUnchangedAudio() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("album.flac"), cue = folder.appendingPathComponent("album.cue")
        try Data([1]).write(to: audio)
        func writeSheet(title: String, secondStart: Int) throws {
            try """
                TITLE "Album"
                PERFORMER "Artist"
                FILE "album.flac" WAVE
                TRACK 01 AUDIO
                TITLE "\(title)"
                INDEX 01 00:00:00
                TRACK 02 AUDIO
                TITLE "Second"
                INDEX 01 00:\(String(format: "%02d", secondStart)):00
                """.write(to: cue, atomically: true, encoding: .utf8)
        }
        try writeSheet(title: "Original", secondStart: 10)
        let source = SourceRecord(kind: .local, name: "Music", location: folder.absoluteString)
        let scanner = LibraryScanner(artworkCacheURL: folder.appendingPathComponent("Artwork"))
        let first = try await scanner.scan(source: source) { _ in AudioFileMetadata(duration: 30, format: "FLAC") }
        let cache = Dictionary(uniqueKeysWithValues: first.fileCacheEntries.map { ($0.path, $0) })
        try writeSheet(title: "Corrected", secondStart: 12)
        let cover = folder.appendingPathComponent("cover.jpg")
        try Data([1, 2, 3]).write(to: cover)
        let refreshed = try await scanner.scan(source: source, cachedFiles: cache) { _ in
            XCTFail("CUE or sidecar changes must not reread unchanged embedded audio metadata.")
            return AudioFileMetadata()
        }
        XCTAssertTrue(refreshed.isComplete)
        XCTAssertEqual(refreshed.filesRead, 0)
        XCTAssertEqual(refreshed.tracks.map(\.id), first.tracks.map(\.id))
        XCTAssertEqual(refreshed.tracks.map(\.title), ["Corrected", "Second"])
        XCTAssertEqual(refreshed.tracks.map(\.duration), [12, 18])
        for track in refreshed.tracks {
            let path = try XCTUnwrap(track.artworkPath)
            XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath(), cover.resolvingSymlinksInPath())
        }
        try FileManager.default.removeItem(at: cover)
        let removedCover = try await scanner.scan(source: source, cachedFiles: cache) { _ in AudioFileMetadata() }
        XCTAssertEqual(removedCover.filesRead, 0)
        XCTAssertTrue(removedCover.tracks.allSatisfy { $0.artworkPath == nil })
    }

    func testFailedOrRacingReadsNeverBecomeReusableCacheEntries() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Track.mp3")
        try Data([1]).write(to: file)
        let source = SourceRecord(kind: .local, name: "Music", location: folder.absoluteString)
        let scanner = LibraryScanner(artworkCacheURL: folder.appendingPathComponent("Artwork"))
        let failed = try await scanner.scan(source: source) { _ in throw CocoaError(.fileReadNoPermission) }
        XCTAssertFalse(failed.isComplete)
        XCTAssertTrue(failed.fileCacheEntries.isEmpty)
        let racing = try await scanner.scan(source: source) { file in
            try Data([1, 2]).write(to: file)
            return AudioFileMetadata(title: "Read during replacement", duration: 30)
        }
        XCTAssertEqual(racing.filesRead, 1)
        XCTAssertTrue(racing.fileCacheEntries.isEmpty)
    }

    func testScanCacheIsSourceIsolatedStripsArtworkBytesAndPreservesPartialEntries() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        let first = SourceRecord(id: "first", kind: .local, name: "First", location: folder.absoluteString)
        let other = SourceRecord(id: "other", kind: .local, name: "Other", location: folder.absoluteString)
        try store.saveSource(first); try store.saveSource(other)
        let metadata = AudioFileMetadata(title: "Cached", duration: 30, artworkData: Data(repeating: 3, count: 128), artworkPath: "/cache/cover.jpg")
        var entry = LocalScanFileCacheEntry(path: "/music/Track.flac", byteCount: 123,
                                          modifiedAt: Date(timeIntervalSinceReferenceDate: 123_456.1234567), metadata: metadata)
        // Defend the storage boundary too if a caller later assigns embedded bytes to the value.
        entry.metadata.artworkData = Data([9])
        try store.saveLocalScanCache(sourceID: first.id, entries: [entry])
        XCTAssertTrue(try store.localScanCache(sourceID: other.id).isEmpty)
        let restored = try XCTUnwrap(store.localScanCache(sourceID: first.id)[entry.path])
        XCTAssertNil(restored.metadata.artworkData)
        XCTAssertEqual(restored.metadata.artworkPath, metadata.artworkPath)
        XCTAssertEqual(restored.modifiedAt, entry.modifiedAt)
        try store.saveLocalScanCache(sourceID: first.id, entries: [], isComplete: false)
        XCTAssertEqual(try store.localScanCache(sourceID: first.id).count, 1)
        try store.saveLocalScanCache(sourceID: first.id, entries: [], isComplete: true)
        XCTAssertTrue(try store.localScanCache(sourceID: first.id).isEmpty)
        try store.saveLocalScanCache(sourceID: first.id, entries: [entry])
        try store.deleteSource(id: first.id)
        XCTAssertTrue(try store.localScanCache(sourceID: first.id).isEmpty)
    }

    func testReplacementAndUpsertWriteOnlyChangedColumnsWithoutLosingUserData() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        let source = SourceRecord(kind: .local, name: "Music", location: folder.absoluteString)
        try store.saveSource(source)
        let track = TrackRecord(id: "track", sourceID: source.id, title: "Original", artworkPath: "/old.jpg")
        let missing = TrackRecord(id: "missing", sourceID: source.id, title: "Missing")
        try store.upsertTracks([track, missing])
        try store.recordPlay(trackID: track.id, at: Date(timeIntervalSince1970: 1_000))
        try store.setRating(trackID: track.id, rating: 4)
        let playlist = try store.savePlaylist(name: "Duplicate", trackIDs: [track.id, track.id])
        try store.database.write { db in
            try db.execute(sql: """
                CREATE TABLE scanWrites (kind TEXT NOT NULL, trackID TEXT NOT NULL);
                CREATE TRIGGER scanAnyUpdate AFTER UPDATE ON tracks BEGIN
                    INSERT INTO scanWrites VALUES ('any', new.id);
                END;
                CREATE TRIGGER scanSearchUpdate AFTER UPDATE OF title, artist, album, albumArtist, genre ON tracks BEGIN
                    INSERT INTO scanWrites VALUES ('search', new.id);
                END;
                """)
        }
        try store.replaceSourceTracks(sourceID: source.id, with: [track, missing])
        XCTAssertEqual(try countWrites(store), 0)
        var artwork = track
        artwork.artworkPath = "/new.jpg"
        try store.replaceSourceTracks(sourceID: source.id, with: [artwork])
        XCTAssertEqual(try countWrites(store), 2, "Only the changed artwork and missing availability should be updated.")
        XCTAssertEqual(try countWrites(store, kind: "search"), 0, "Artwork and availability must not rebuild FTS.")
        try store.upsertTracks([artwork])
        XCTAssertEqual(try countWrites(store), 2)
        var retagged = artwork
        retagged.title = "Retagged"
        try store.upsertTracks([retagged])
        XCTAssertEqual(try countWrites(store, kind: "search"), 1)
        XCTAssertEqual(try store.tracks(sourceID: source.id, query: "Retagged").map(\.id), [track.id])
        let restored = try XCTUnwrap(store.track(id: track.id))
        XCTAssertEqual(restored.playCount, 1)
        XCTAssertEqual(restored.rating, 4)
        XCTAssertEqual(restored.lastPlayedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(try store.playlistTracks(id: playlist.id).map(\.id), [track.id, track.id])
    }

    func testFastScansCoalesceProgressAndAlwaysPublishFinalCount() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<250 { try Data([1]).write(to: folder.appendingPathComponent("\(index).mp3")) }
        let progress = ScanProgressRecorder()
        let source = SourceRecord(kind: .local, name: "Music", location: folder.absoluteString)
        let result = try await LibraryScanner().scan(source: source, metadataReader: { _ in AudioFileMetadata(duration: 1) }, progress: { count, total in
            progress.append(count, total: total)
        })
        let events = progress.events
        XCTAssertEqual(result.filesScanned, 250)
        XCTAssertEqual(events.last?.0, 250)
        XCTAssertEqual(events.last?.1, 250)
        XCTAssertLessThan(events.count, 50, "A fast scan must not enqueue one MainActor progress task per file.")
    }

    private func countWrites(_ store: LibraryStore, kind: String = "any") throws -> Int {
        try store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM scanWrites WHERE kind = ?", arguments: [kind]) ?? 0 }
    }

    private func temporaryFolder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokIncrementalScan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class ScanProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, Int)] = []
    func append(_ count: Int, total: Int) { lock.lock(); defer { lock.unlock() }; values.append((count, total)) }
    var events: [(Int, Int)] { lock.lock(); defer { lock.unlock() }; return values }
}
