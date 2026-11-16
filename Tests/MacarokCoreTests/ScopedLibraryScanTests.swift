import Foundation
import GRDB
import XCTest
@testable import MacarokCore

final class ScopedLibraryScanTests: XCTestCase {
    func testNarrowScanReadsOnlyItsCacheAndReportsNoOpWithoutLosingUserValues() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let selected = try writeAudio("Artist/Album %_é/First.flac", root: fixture.root)
        let other = try writeAudio("Artist/Album %_é extra/Other.flac", root: fixture.root)
        let first = try await scan(fixture)
        try save(first, fixture: fixture)
        let selectedTrack = try XCTUnwrap(first.tracks.first { $0.url?.path == selected.path })
        try fixture.store.recordPlay(trackID: selectedTrack.id, at: Date(timeIntervalSince1970: 1_000))
        try fixture.store.setRating(trackID: selectedTrack.id, rating: 4)
        var corrected = try XCTUnwrap(fixture.store.track(id: selectedTrack.id))
        corrected.title = "User correction"
        try fixture.store.updateTrackMetadata(corrected)
        // A malformed unrelated blob proves a bounded cache read does not depend on decoding it.
        try await fixture.store.database.write { db in
            try db.execute(sql: "UPDATE localScanFiles SET metadata = ? WHERE sourceID = ? AND path = ?",
                           arguments: [Data([0]), fixture.source.id, other.path])
        }
        let requested = LocalScanCoverage.folders(["Artist/Album %_é"])
        let coverage = try fixture.store.localScanCoverage(sourceID: fixture.source.id, requested: requested)
        XCTAssertEqual(coverage, requested)
        let cache = try fixture.store.localScanCache(sourceID: fixture.source.id, coverage: coverage)
        XCTAssertEqual(Set(cache.keys), [selected.path])
        let refreshed = try await fixture.scanner.scan(source: fixture.source, cachedFiles: cache, coverage: coverage) { _ in
            XCTFail("A narrow unchanged scan must not reopen any audio.")
            return AudioFileMetadata()
        }
        XCTAssertEqual(refreshed.coverage, coverage)
        XCTAssertEqual(refreshed.tracks.count, 1)
        XCTAssertEqual(refreshed.filesRead, 0)
        XCTAssertFalse(try fixture.store.replaceSourceTracks(sourceID: fixture.source.id, with: refreshed.tracks, coverage: refreshed.coverage),
                       "Fresh scan dates, statistics, and locked corrections must not manufacture index changes.")
        XCTAssertFalse(try fixture.store.upsertTracks(refreshed.tracks))
        try fixture.store.saveLocalScanCache(sourceID: fixture.source.id, entries: refreshed.fileCacheEntries, coverage: refreshed.coverage)
        let saved = try XCTUnwrap(fixture.store.track(id: selectedTrack.id))
        XCTAssertEqual(saved.title, "User correction")
        XCTAssertEqual(saved.rating, 4)
        XCTAssertEqual(saved.playCount, 1)
        XCTAssertEqual(saved.lastPlayedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(try XCTUnwrap(fixture.store.track(id: first.tracks.first { $0.url?.path == other.path }!.id)).isAvailable)
        let untouchedData = try await fixture.store.database.read { try Data.fetchOne($0, sql: "SELECT metadata FROM localScanFiles WHERE sourceID = ? AND path = ?",
            arguments: [fixture.source.id, other.path]) }
        XCTAssertEqual(untouchedData, Data([0]))

        var cached = try XCTUnwrap(cache[selected.path])
        cached.metadata.artworkPath = fixture.container.appendingPathComponent("replacement-cover.jpg").path
        try fixture.store.saveLocalScanCache(sourceID: fixture.source.id, entries: [cached], coverage: coverage)
        XCTAssertEqual(try fixture.store.localScanCache(sourceID: fixture.source.id, coverage: coverage)[selected.path]?.metadata.artworkPath,
                       cached.metadata.artworkPath, "Equal size/mtime must not hide a changed cached artwork path.")
    }

    func testRenamedAndDeletedFoldersReconcileOnlyTheirOwnTracksAndCache() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let old = try writeAudio("Old/Track.flac", root: fixture.root)
        let other = try writeAudio("Other/Keep.flac", root: fixture.root)
        let first = try await scan(fixture)
        try save(first, fixture: fixture)
        let oldTrack = try XCTUnwrap(first.tracks.first { $0.url?.path == old.path })
        let otherTrack = try XCTUnwrap(first.tracks.first { $0.url?.path == other.path })
        try fixture.store.recordPlay(trackID: oldTrack.id)
        try FileManager.default.moveItem(at: old.deletingLastPathComponent(), to: fixture.root.appendingPathComponent("New", isDirectory: true))
        let coverage = LocalScanCoverage.folders(["Old", "New"]).normalized
        let result = try await fixture.scanner.scan(source: fixture.source,
            cachedFiles: fixture.store.localScanCache(sourceID: fixture.source.id, coverage: coverage), coverage: coverage,
            metadataReader: Self.metadata)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.filesScanned, 1)
        XCTAssertTrue(try fixture.store.replaceSourceTracks(sourceID: fixture.source.id, with: result.tracks, coverage: result.coverage))
        try fixture.store.saveLocalScanCache(sourceID: fixture.source.id, entries: result.fileCacheEntries, coverage: result.coverage)
        XCTAssertFalse(try XCTUnwrap(fixture.store.track(id: oldTrack.id)).isAvailable)
        XCTAssertEqual(try fixture.store.track(id: oldTrack.id)?.playCount, 1)
        XCTAssertTrue(try XCTUnwrap(fixture.store.track(id: otherTrack.id)).isAvailable)
        XCTAssertEqual(try fixture.store.localScanCache(sourceID: fixture.source.id).count, 2)
        XCTAssertNil(try fixture.store.localScanCache(sourceID: fixture.source.id)[old.path])

        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("New"))
        let deleted = try await fixture.scanner.scan(source: fixture.source, coverage: .folders(["New"]), metadataReader: Self.metadata)
        XCTAssertTrue(deleted.isComplete)
        XCTAssertTrue(deleted.tracks.isEmpty)
        XCTAssertTrue(try fixture.store.replaceSourceTracks(sourceID: fixture.source.id, with: [], coverage: deleted.coverage))
        XCTAssertFalse(try fixture.store.replaceSourceTracks(sourceID: fixture.source.id, with: [], coverage: deleted.coverage))
        XCTAssertTrue(try XCTUnwrap(fixture.store.track(id: otherTrack.id)).isAvailable)
    }

    func testCrossFolderCUEChangesAndDeletionPreserveUnrelatedAlbums() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        _ = try writeAudio("Audio/Image.flac", root: fixture.root)
        let other = try writeAudio("Other/Keep.flac", root: fixture.root)
        let sheet = try writeCUE(root: fixture.root, reference: "../Audio/Image.flac")
        let first = try await scan(fixture)
        try save(first, fixture: fixture)
        let originalIDs = Set(first.tracks.filter { $0.cuePath != nil }.map(\.id))
        XCTAssertEqual(originalIDs.count, 2)
        let coverage = try fixture.store.localScanCoverage(sourceID: fixture.source.id, requested: .folders(["Audio"]))
        XCTAssertEqual(coverage, .folders(["Audio", "Sheets"]))
        let refreshed = try await fixture.scanner.scan(source: fixture.source,
            cachedFiles: fixture.store.localScanCache(sourceID: fixture.source.id, coverage: coverage), coverage: coverage) { _ in
                XCTFail("Dependent CUE folders must share the bounded unchanged-audio cache.")
                return AudioFileMetadata()
            }
        XCTAssertTrue(refreshed.isComplete)
        XCTAssertEqual(Set(refreshed.tracks.map(\.id)), originalIDs)
        XCTAssertFalse(try fixture.store.replaceSourceTracks(sourceID: fixture.source.id, with: refreshed.tracks, coverage: coverage))
        try FileManager.default.removeItem(at: sheet)
        let removed = try await fixture.scanner.scan(source: fixture.source,
            cachedFiles: fixture.store.localScanCache(sourceID: fixture.source.id, coverage: coverage), coverage: coverage, metadataReader: Self.metadata)
        XCTAssertTrue(removed.isComplete)
        XCTAssertEqual(removed.tracks.count, 1, "Removing a sheet exposes the physical audio once.")
        XCTAssertNil(removed.tracks.first?.cuePath)
        try save(removed, fixture: fixture)
        for id in originalIDs { XCTAssertFalse(try XCTUnwrap(fixture.store.track(id: id)).isAvailable) }
        XCTAssertTrue(try XCTUnwrap(fixture.store.track(id: first.tracks.first { $0.url?.path == other.path }!.id)).isAvailable)
        let referenceCount = try await fixture.store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM localScanCUEReferences") }
        XCTAssertEqual(referenceCount, 0)
    }

    func testMissingCUEReferencesRemainDependenciesUntilTheAudioArrives() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        _ = try writeCUE(root: fixture.root, reference: "../Audio/Later.flac")
        let incomplete = try await scan(fixture)
        XCTAssertFalse(incomplete.isComplete)
        try fixture.store.saveLocalScanCache(sourceID: fixture.source.id, entries: incomplete.fileCacheEntries, isComplete: false)
        _ = try writeAudio("Audio/Later.flac", root: fixture.root)
        let coverage = try fixture.store.localScanCoverage(sourceID: fixture.source.id, requested: .folders(["Audio"]))
        XCTAssertEqual(coverage, .folders(["Audio", "Sheets"]))
        let complete = try await fixture.scanner.scan(source: fixture.source, coverage: coverage, metadataReader: Self.metadata)
        XCTAssertTrue(complete.isComplete)
        XCTAssertEqual(complete.tracks.count, 2)
        XCTAssertTrue(complete.tracks.allSatisfy { $0.cuePath != nil })
    }

    func testNewCrossFolderCUEAndRelocatedBookmarkEscalateToCompleteCoverage() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        _ = try writeAudio("Audio/Image.flac", root: fixture.root)
        _ = try writeAudio("Other/Keep.flac", root: fixture.root)
        _ = try writeCUE(root: fixture.root, reference: "../Audio/Image.flac")
        let result = try await fixture.scanner.scan(source: fixture.source, coverage: .folders(["Sheets"]), metadataReader: Self.metadata)
        XCTAssertEqual(result.coverage, .all)
        XCTAssertEqual(result.tracks.count, 3)
        XCTAssertEqual(try fixture.store.localScanCoverage(sourceID: fixture.source.id, requested: .folders(["Audio"]),
            rootURL: fixture.container.appendingPathComponent("Relocated", isDirectory: true)), .all)
    }

    func testFolderArtworkRefreshUsesRawMetadataCacheAndLeavesOtherFoldersUntouched() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let audio = try writeAudio("Album/Track.flac", root: fixture.root)
        let other = try writeAudio("Other/Keep.flac", root: fixture.root)
        let first = try await scan(fixture)
        try save(first, fixture: fixture)
        let coverage = LocalScanCoverage.folders(["Album"])
        let cache = try fixture.store.localScanCache(sourceID: fixture.source.id, coverage: coverage)
        let cover = audio.deletingLastPathComponent().appendingPathComponent("cover.jpg")
        try Data([1, 2, 3]).write(to: cover)
        let added = try await fixture.scanner.scan(source: fixture.source, cachedFiles: cache, coverage: coverage) { _ in
            XCTFail("Folder artwork must not reopen unchanged audio metadata.")
            return AudioFileMetadata()
        }
        XCTAssertEqual(added.filesRead, 0)
        let artworkPath = try XCTUnwrap(added.tracks.first?.artworkPath)
        XCTAssertEqual(URL(fileURLWithPath: artworkPath).resolvingSymlinksInPath(), cover.resolvingSymlinksInPath())
        XCTAssertNil(added.fileCacheEntries.first { $0.path == audio.path }?.metadata.artworkPath,
                     "A folder sidecar must not become a cached embedded-artwork reference.")
        XCTAssertTrue(try fixture.store.replaceSourceTracks(sourceID: fixture.source.id, with: added.tracks, coverage: coverage))
        XCTAssertNil(try fixture.store.track(id: first.tracks.first { $0.url?.path == other.path }!.id)?.artworkPath)
        try FileManager.default.removeItem(at: cover)
        let removed = try await fixture.scanner.scan(source: fixture.source, cachedFiles: cache, coverage: coverage,
                                                    metadataReader: Self.metadata)
        XCTAssertEqual(removed.filesRead, 0)
        XCTAssertNil(removed.tracks.first?.artworkPath)
        XCTAssertTrue(try fixture.store.replaceSourceTracks(sourceID: fixture.source.id, with: removed.tracks, coverage: coverage))
    }

    func testPartialReadsPreservePreviousMetadataCacheAndAvailability() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let audio = try writeAudio("Album/Track.flac", root: fixture.root)
        _ = try writeAudio("Other/Keep.flac", root: fixture.root)
        let first = try await scan(fixture)
        try save(first, fixture: fixture)
        try Data([1, 2, 3]).write(to: audio)
        let coverage = LocalScanCoverage.folders(["Album"])
        let result = try await fixture.scanner.scan(source: fixture.source,
            cachedFiles: fixture.store.localScanCache(sourceID: fixture.source.id, coverage: coverage), coverage: coverage) { _ in
                throw CocoaError(.fileReadNoPermission)
            }
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.tracks.isEmpty, "A failed read must not replace valid tags with filename fallbacks.")
        XCTAssertFalse(try fixture.store.upsertTracks(result.tracks))
        try fixture.store.saveLocalScanCache(sourceID: fixture.source.id, entries: result.fileCacheEntries,
                                             isComplete: result.isComplete, coverage: result.coverage)
        XCTAssertEqual(try fixture.store.tracks(sourceID: fixture.source.id).count, first.tracks.count)
        XCTAssertEqual(try fixture.store.localScanCache(sourceID: fixture.source.id).count, 2)
        XCTAssertEqual(try fixture.store.track(id: first.tracks.first { $0.url?.path == audio.path }!.id)?.title, "Track")
    }

    private struct Fixture: Sendable {
        let container: URL
        let root: URL
        let source: SourceRecord
        let store: LibraryStore
        let scanner: LibraryScanner
    }

    private func makeFixture() throws -> Fixture {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokScopedScan-\(UUID().uuidString)").resolvingSymlinksInPath()
        let root = container.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try LibraryStore(url: container.appendingPathComponent("library.sqlite"))
        let source = SourceRecord(kind: .local, name: "Music", location: root.absoluteString)
        try store.saveSource(source)
        return Fixture(container: container, root: root, source: source, store: store,
                       scanner: LibraryScanner(artworkCacheURL: container.appendingPathComponent("Artwork")))
    }

    private func scan(_ fixture: Fixture) async throws -> LibraryScanResult {
        try await fixture.scanner.scan(source: fixture.source, metadataReader: Self.metadata)
    }

    private func save(_ result: LibraryScanResult, fixture: Fixture) throws {
        if result.isComplete { try fixture.store.replaceSourceTracks(sourceID: fixture.source.id, with: result.tracks, coverage: result.coverage) }
        else { try fixture.store.upsertTracks(result.tracks) }
        try fixture.store.saveLocalScanCache(sourceID: fixture.source.id, entries: result.fileCacheEntries,
                                             isComplete: result.isComplete, coverage: result.coverage)
    }

    private static let metadata: @Sendable (URL) throws -> AudioFileMetadata = { url in
        AudioFileMetadata(title: url.deletingPathExtension().lastPathComponent, artist: "Artist", album: "Album", duration: 60, format: "FLAC")
    }

    private func writeAudio(_ path: String, root: URL) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: url)
        return url
    }

    private func writeCUE(root: URL, reference: String) throws -> URL {
        let url = root.appendingPathComponent("Sheets/Album.cue")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
            TITLE "Album"
            PERFORMER "Artist"
            FILE "\(reference)" WAVE
            TRACK 01 AUDIO
            TITLE "First"
            INDEX 01 00:00:00
            TRACK 02 AUDIO
            TITLE "Second"
            INDEX 01 00:30:00
            """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
