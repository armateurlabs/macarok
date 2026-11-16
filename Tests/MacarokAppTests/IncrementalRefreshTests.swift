import Foundation
import GRDB
import MacarokCore
import XCTest
@testable import MacarokApp

@MainActor
final class IncrementalRefreshTests: XCTestCase {
    func testUnchangedRefreshSkipsSnapshotPublicationAndScopedDeletionKeepsOtherFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokScopedRefresh-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let music = root.appendingPathComponent("Music", isDirectory: true)
        for folder in ["First", "Second"] {
            let url = music.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: url.appendingPathComponent("song.flac"))
        }
        let source = SourceRecord(id: "source", kind: .local, name: "Music", location: music.absoluteString)
        let store = try LibraryStore(url: root.appendingPathComponent("library.sqlite"))
        try store.saveSource(source)
        let initial = try await LibraryScanner().scan(source: source) { file in
            AudioFileMetadata(title: file.deletingLastPathComponent().lastPathComponent, artist: "Artist", album: "Album", duration: 30)
        }
        try store.replaceSourceTracks(sourceID: source.id, with: initial.tracks)
        try store.saveLocalScanCache(sourceID: source.id, entries: initial.fileCacheEntries)
        let counter = RefreshSnapshotCounter()
        let model = AppModel(store: store, registerSystemControls: false, scopedSnapshotLoader: { scope, store, sources in
            await counter.increment()
            return try await Task.detached {
                try LibrarySnapshot.build(scope: scope, tracks: store.tracks(scope: scope), sources: sources)
            }.value
        })
        await model.start()
        let baseline = await counter.value
        let revision = model.libraryRevision
        model.refresh()
        try await waitForRefresh(model)
        let unchanged = await counter.value
        XCTAssertEqual(unchanged, baseline, "An unchanged import must not rebuild or publish a catalog.")
        XCTAssertEqual(model.libraryRevision, revision)
        XCTAssertEqual(model.tracks.count, 2)

        try FileManager.default.removeItem(at: music.appendingPathComponent("First/song.flac"))
        model.requestRescan(sourceID: source.id, coverage: .folders(["First"]))
        try await waitForRefresh(model)
        XCTAssertEqual(model.tracks.map(\.title), ["Second"])
        let updated = await counter.value
        XCTAssertEqual(updated, baseline + 1)
        XCTAssertEqual(try store.localScanCache(sourceID: source.id).count, 1)
        XCTAssertNil(model.message)
        await model.finishPlaybackAccess()
    }

    func testCommittedIndexPublishesAfterCacheFailureAndNoOpRefreshRepairsCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokCacheFailure-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let music = root.appendingPathComponent("Music", isDirectory: true)
        for folder in ["First", "Second"] {
            let url = music.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: url.appendingPathComponent("song.flac"))
        }
        let source = SourceRecord(id: "source", kind: .local, name: "Music", location: music.absoluteString)
        let store = try LibraryStore(url: root.appendingPathComponent("library.sqlite"))
        try store.saveSource(source)
        let initial = try await LibraryScanner().scan(source: source) { file in
            AudioFileMetadata(title: file.deletingLastPathComponent().lastPathComponent, artist: "Artist", album: "Album", duration: 30)
        }
        try store.replaceSourceTracks(sourceID: source.id, with: initial.tracks)
        try store.saveLocalScanCache(sourceID: source.id, entries: initial.fileCacheEntries)
        let counter = RefreshSnapshotCounter()
        let model = AppModel(store: store, registerSystemControls: false, scopedSnapshotLoader: { scope, store, sources in
            await counter.increment()
            return try await Task.detached {
                try LibrarySnapshot.build(scope: scope, tracks: store.tracks(scope: scope), sources: sources)
            }.value
        })
        await model.start()
        let baseline = await counter.value
        try await store.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER failLocalScanCacheDelete BEFORE DELETE ON localScanFiles BEGIN
                    SELECT RAISE(ABORT, 'Injected cache persistence failure');
                END;
                """)
        }
        try FileManager.default.removeItem(at: music.appendingPathComponent("First/song.flac"))
        model.requestRescan(sourceID: source.id, coverage: .folders(["First"]))
        try await waitForRefresh(model)
        XCTAssertEqual(model.tracks.map(\.title), ["Second"],
                       "A cache failure after the track transaction commits must not hide the committed index.")
        XCTAssertEqual(try store.tracks(sourceID: source.id).map(\.title), ["Second"])
        let published = await counter.value
        XCTAssertEqual(published, baseline + 1)
        XCTAssertEqual(try store.localScanCache(sourceID: source.id).count, 2, "The failed cache transaction retains both previous rows.")
        XCTAssertTrue(model.message?.detail.contains("Injected cache persistence failure") == true)

        try await store.database.write { try $0.execute(sql: "DROP TRIGGER failLocalScanCacheDelete") }
        model.message = nil
        model.requestRescan(sourceID: source.id, coverage: .folders(["First"]))
        try await waitForRefresh(model)
        XCTAssertEqual(model.tracks.map(\.title), ["Second"])
        XCTAssertEqual(try store.localScanCache(sourceID: source.id).count, 1)
        let repaired = await counter.value
        XCTAssertEqual(repaired, published, "Repairing only the cache must not rebuild an already published unchanged catalog.")
        XCTAssertNil(model.message)
        await model.finishPlaybackAccess()
    }

    private func waitForRefresh(_ model: AppModel) async throws {
        for _ in 0..<500 {
            if !model.isRefreshing { await model.waitForLibraryLoad(); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The refresh did not finish.")
    }
}

private actor RefreshSnapshotCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
