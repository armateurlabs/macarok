import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

final class AllSourcesSnapshotTests: XCTestCase {
    func testAllScopeKeepsDuplicateAlbumsAndTracksButUnifiesNormalizedArtistNames() throws {
        let a = source("a"), b = source("b")
        let first = track("first", source: a, artist: "The  Artist", count: 4)
        let second = track("second", source: b, artist: " the ARTIST \n", count: 7)
        var unavailable = track("missing", source: b)
        unavailable.isAvailable = false
        let snapshot = try LibrarySnapshot.build(scope: .all, tracks: [first, second, unavailable], sources: [a, b])

        XCTAssertEqual(snapshot.scope, .all)
        XCTAssertNil(snapshot.sourceID)
        XCTAssertEqual(Set(snapshot.tracks.map(\.id)), [first.id, second.id])
        XCTAssertEqual(snapshot.albums.count, 2)
        XCTAssertEqual(Set(snapshot.albums.map(\.id)), ["shared-album"])
        XCTAssertEqual(Set(snapshot.albums.map(\.presentationID)).count, 2)
        XCTAssertEqual(snapshot.albumsByID.count, 2)
        XCTAssertEqual(snapshot.artists.count, 1)
        XCTAssertEqual(snapshot.artists.first?.sourceIDs, [a.id, b.id])
        XCTAssertEqual(snapshot.artists.first?.trackCount, 2)
        XCTAssertEqual(snapshot.artists.first?.playCount, 11)
        XCTAssertEqual(snapshot.mostPlayedArtists.first?.playCount, 11)
        XCTAssertEqual(snapshot.artistsByName["the artist"]?.albums.count, 2)
        XCTAssertEqual(snapshot.mostPlayedTracks.map(\.id), [second.id, first.id])
    }

    func testAllFoldersKeepIdenticalPathsUnderTheirOwningSource() throws {
        let a = source("a"), b = source("b")
        let first = track("first", source: a), second = track("second", source: b)
        let snapshot = try LibrarySnapshot.build(scope: .all, tracks: [first, second], sources: [a, b])
        XCTAssertEqual(snapshot.folderNodes.map(\.name), [a.name, b.name])
        let rootA = try XCTUnwrap(snapshot.folderNodes.first)
        let rootB = try XCTUnwrap(snapshot.folderNodes.last)
        XCTAssertNotEqual(rootA.id, rootB.id)
        XCTAssertEqual(snapshot.tracksByFolder[rootA.id]?.map(\.id), [first.id])
        XCTAssertEqual(snapshot.tracksByFolder[rootB.id]?.map(\.id), [second.id])
        XCTAssertEqual(snapshot.tracksByFolder[rootA.id + "/Rock/Live"]?.map(\.id), [first.id])
        XCTAssertEqual(snapshot.tracksByFolder[rootB.id + "/Rock/Live"]?.map(\.id), [second.id])
        XCTAssertEqual(snapshot.tracksByFolder[""]?.count, 2)
        XCTAssertNil(snapshot.tracksByFolder["Rock/Live"])
        XCTAssertEqual(snapshot.folderTitles[rootA.id], a.name)
    }

    func testGlobalMostPlayedAggregatesArtistsBeforeLimitingTheResult() throws {
        let a = source("a"), b = source("b")
        var tracks: [TrackRecord] = []
        for index in 0..<10 {
            var other = track("other-\(index)", source: a, artist: "Other \(index)", count: 10)
            other.albumID = "other-album-\(index)"
            other.album = "Other Album \(index)"
            tracks.append(other)
        }
        tracks += [track("shared-a", source: a, artist: "Shared Artist", count: 8),
                   track("shared-b", source: b, artist: "shared artist", count: 8)]
        let snapshot = try LibrarySnapshot.build(scope: .all, tracks: tracks, sources: [a, b])
        XCTAssertEqual(snapshot.mostPlayedArtists.count, 8)
        XCTAssertEqual(snapshot.mostPlayedArtists.first?.playCount, 16)
        XCTAssertEqual(snapshot.mostPlayedArtists.first?.sourceIDs, [a.id, b.id])
    }

    func testAnUnregisteredSourceCannotReappearFromAnOlderAllSnapshotInput() throws {
        let a = source("a"), b = source("b")
        let snapshot = try LibrarySnapshot.build(scope: .all, tracks: [track("a", source: a), track("b", source: b)], sources: [a])
        XCTAssertEqual(snapshot.tracks.map(\.sourceID), [a.id])
        XCTAssertEqual(snapshot.folderNodes.map(\.name), [a.name])
    }

    private func source(_ id: String) -> SourceRecord {
        SourceRecord(id: id, kind: .openSubsonic, name: "Source \(id)", location: "https://\(id).invalid")
    }
    private func track(_ id: String, source: SourceRecord, artist: String = "Artist", count: Int = 0) -> TrackRecord {
        var track = TrackRecord(id: id, sourceID: source.id, albumID: "shared-album", title: "Same Song", artist: artist,
                                album: "Same Album", duration: 120, remoteID: id, remotePath: "Rock/Live/\(id).flac", format: "FLAC")
        track.playCount = count
        return track
    }
}

@MainActor
final class AllSourcesModelTests: XCTestCase {
    func testLegacySelectionMigratesAndAllSelectionSurvivesRestartWithoutFetchingCatalogs() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let suite = "MacarokScopeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(fixture.sourceB.id, forKey: "Macarok.selectedSource")
        let script = AllCatalogScript()
        let model = AppModel(store: fixture.store, preferences: quietPreferences(), registerSystemControls: false,
                             remoteCatalog: { source, receive in try await script.run(sourceID: source.id, receive: receive) }, selectionDefaults: defaults)
        await model.start()
        XCTAssertEqual(model.libraryScope, .source(fixture.sourceB.id))
        model.libraryScope = .all
        await model.waitForLibraryLoad()
        XCTAssertEqual(Set(model.tracks.map(\.sourceID)), [fixture.sourceA.id, fixture.sourceB.id])
        XCTAssertEqual(model.scopeTitle, "All Sources")
        XCTAssertEqual(model.sourceName(for: fixture.sourceB.id), fixture.sourceB.name)
        let restored = AppModel(store: fixture.store, preferences: quietPreferences(), registerSystemControls: false, selectionDefaults: defaults)
        await restored.start()
        XCTAssertEqual(restored.libraryScope, .all)
        XCTAssertEqual(restored.tracks.count, 2)
        let calls = await script.sourceIDs
        XCTAssertTrue(calls.isEmpty, "Selecting cached All Sources must not start a remote import.")
    }

    func testCancelledSourceConnectionsDoNotStartOrChangeTheLibrary() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        await fixture.model.start()
        let podcast = Task { try await fixture.model.addPodcast(address: "https://cancelled.invalid/feed") }
        podcast.cancel()
        do { try await podcast.value; XCTFail("A cancelled subscription must stop before requesting its feed.") }
        catch is CancellationError { }
        let server = Task { try await fixture.model.addServer(name: "Cancelled", address: "https://cancelled.invalid", credentials: SourceCredentials(username: "unused")) }
        server.cancel()
        do { try await server.value; XCTFail("A cancelled connection must stop before writing credentials.") }
        catch is CancellationError { }
        XCTAssertEqual(try fixture.store.sources().count, 2)
        XCTAssertEqual(fixture.model.sources.count, 2)
        XCTAssertFalse(fixture.model.isRefreshing)
    }

    func testAllSearchUpdatesEveryGroupingAndAlbumInspectionRetainsTheOrigin() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        await model.start()
        model.libraryScope = .all
        await model.waitForLibraryLoad()
        model.search = "Common"
        try await eventually { !model.isSearching }
        XCTAssertEqual(model.visibleAlbums.count, 2)
        XCTAssertEqual(model.artists.count, 1)
        XCTAssertEqual(model.artists.first?.sourceIDs, [fixture.sourceA.id, fixture.sourceB.id])
        XCTAssertEqual(model.yearGroups.first?.albums.count, 2)
        XCTAssertEqual(model.genreGroups.first?.tracks.count, 2)
        let albumB = try XCTUnwrap(model.visibleAlbums.first { $0.sourceID == fixture.sourceB.id })
        model.inspect(albumB)
        XCTAssertEqual(model.selectedAlbum?.sourceID, fixture.sourceB.id)
        XCTAssertEqual(model.tracksForAlbum(albumB).map(\.id), [fixture.trackB.id])
        model.inspectAlbum(containing: fixture.trackA)
        XCTAssertEqual(model.selectedAlbum?.sourceID, fixture.sourceA.id)
        XCTAssertEqual(model.libraryScope, .all)
        model.queue = [QueueItem(track: fixture.trackB)]
        model.currentQueueID = model.queue[0].id
        model.showCurrentTrack()
        XCTAssertEqual(model.libraryScope, .all)
        XCTAssertEqual(model.currentTrack?.sourceID, fixture.sourceB.id)
        let rootB = try XCTUnwrap(model.folderNodes.first { $0.name == fixture.sourceB.name })
        model.inspectFolder(rootB.id)
        XCTAssertEqual(model.folderTitle, fixture.sourceB.name)
        XCTAssertEqual(model.folderTracks.map(\.id), [fixture.trackB.id])
    }

    func testLateAllSnapshotCannotPublishAfterRemovingASource() async throws {
        let gate = AllSnapshotGate()
        let fixture = try makeFixture(gate: gate)
        defer { fixture.cleanup(); Task { await gate.releaseAll() } }
        let model = fixture.model
        await model.start()
        model.libraryScope = .all
        await model.waitForLibraryLoad()
        await gate.hold()
        model.reloadLibrary()
        try await requireRequests(gate, count: 1)
        try fixture.store.deleteSource(id: fixture.sourceB.id)
        model.sources = try fixture.store.sources()
        XCTAssertEqual(model.libraryScope, .all)
        XCTAssertTrue(model.tracks.isEmpty)
        await gate.release(0)
        try await requireRequests(gate, count: 2)
        XCTAssertTrue(model.tracks.isEmpty, "The old source membership must never be published.")
        await gate.release(1)
        try await eventually { !model.isLoadingLibrary }
        XCTAssertEqual(model.tracks.map(\.id), [fixture.trackA.id])
        XCTAssertEqual(model.folderNodes.map(\.name), [fixture.sourceA.name])
    }

    func testAddingASourceKeepsAllSelectedAndRejectsTheOldMembershipSnapshot() async throws {
        let gate = AllSnapshotGate()
        let fixture = try makeFixture(gate: gate)
        defer { fixture.cleanup(); Task { await gate.releaseAll() } }
        let model = fixture.model
        await model.start()
        model.libraryScope = .all
        await model.waitForLibraryLoad()
        await gate.hold()
        model.reloadLibrary()
        try await requireRequests(gate, count: 1)
        let added = SourceRecord(id: "c", kind: .openSubsonic, name: "Source C", location: "https://c.invalid")
        let track = TrackRecord(id: "c-track", sourceID: added.id, title: "Third", artist: "Third", album: "Third")
        try fixture.store.saveSource(added)
        try fixture.store.upsertTracks([track])
        model.sources = try fixture.store.sources()
        model.selectAddedSource(added.id)
        await gate.release(0)
        try await requireRequests(gate, count: 2)
        await gate.release(1)
        try await eventually { !model.isLoadingLibrary }
        XCTAssertEqual(model.libraryScope, .all)
        XCTAssertEqual(model.tracks.count, 3)
        XCTAssertEqual(model.folderNodes.count, 3)
    }

    func testRefreshAllIsSerialPublishesPartialBatchesAndContinuesAfterAFailure() async throws {
        let script = AllCatalogScript()
        let fixture = try makeFixture(script: script)
        defer { fixture.cleanup(); Task { await script.finishAll() } }
        let model = fixture.model
        await model.start()
        model.libraryScope = .all
        await model.waitForLibraryLoad()
        model.refresh()
        try await requireRuns(script, count: 1)
        var first = fixture.trackA
        first.id = "new-a"; first.title = "New A"
        try await script.emit([first], run: 0)
        XCTAssertTrue(model.tracks.contains { $0.id == first.id })
        XCTAssertTrue(model.isRefreshing)
        let started = await script.sourceIDs
        XCTAssertEqual(started, [fixture.sourceA.id], "The second origin waits for the first operation to finish.")
        await script.finish(0, error: URLError(.networkConnectionLost))
        try await requireRuns(script, count: 2)
        XCTAssertTrue(model.refreshProgress.contains(fixture.sourceB.name))
        var second = fixture.trackB
        second.id = "new-b"; second.title = "New B"
        try await script.emit([second], run: 1)
        await script.finish(1)
        try await eventually { !model.isRefreshing }
        let completedSources = await script.sourceIDs
        XCTAssertEqual(completedSources, [fixture.sourceA.id, fixture.sourceB.id])
        XCTAssertTrue(model.tracks.contains { $0.id == first.id })
        XCTAssertTrue(model.tracks.contains { $0.id == fixture.trackA.id }, "Failure does not reconcile away cached tracks.")
        XCTAssertEqual(try fixture.store.track(id: fixture.trackB.id)?.isAvailable, false, "A complete source still reconciles normally.")
        XCTAssertNotNil(model.message)
        XCTAssertTrue(model.message?.detail.contains(fixture.sourceA.name) == true)
        XCTAssertEqual(model.libraryScope, .all)
    }

    func testCancellingRefreshAllPreservesPartialDataAndDoesNotStartTheNextSource() async throws {
        let script = AllCatalogScript()
        let fixture = try makeFixture(script: script)
        defer { fixture.cleanup(); Task { await script.finishAll() } }
        let model = fixture.model
        await model.start()
        model.libraryScope = .all
        await model.waitForLibraryLoad()
        model.refresh()
        try await requireRuns(script, count: 1)
        try await script.emit([fixture.trackA], run: 0)
        model.cancelRefresh()
        await script.finish(0)
        try await eventually { !model.isRefreshing }
        let started = await script.sourceIDs
        XCTAssertEqual(started, [fixture.sourceA.id])
        XCTAssertNotNil(try fixture.store.track(id: fixture.trackA.id))
        XCTAssertNil(model.message)
    }

    func testFolderChangesQueueEachVisibleLocalOriginWhileRefreshingAll() async throws {
        let gate = AllScanGate()
        let fixture = try makeFixture(local: true, scanGate: gate)
        defer { fixture.cleanup(); Task { await gate.releaseAll() } }
        let model = fixture.model
        await model.start()
        model.libraryScope = .all
        await model.waitForLibraryLoad()
        model.refresh()
        try await requireScans(gate, count: 1)
        model.requestRescan(sourceID: fixture.sourceA.id)
        model.requestRescan(sourceID: fixture.sourceB.id)
        await gate.release(0)
        try await requireScans(gate, count: 2)
        await gate.release(1)
        try await requireScans(gate, count: 3)
        await gate.release(2)
        try await requireScans(gate, count: 4)
        await gate.release(3)
        try await eventually { !model.isRefreshing }
        let scanned = await gate.sourceIDs
        XCTAssertEqual(scanned, [fixture.sourceA.id, fixture.sourceB.id, fixture.sourceA.id, fixture.sourceB.id])
        XCTAssertEqual(model.libraryScope, .all)
    }

    private func makeFixture(gate: AllSnapshotGate? = nil, script: AllCatalogScript? = nil,
                             local: Bool = false, scanGate: AllScanGate? = nil) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokAllSources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try LibraryStore(url: directory.appendingPathComponent("test.sqlite"))
        let aURL = directory.appendingPathComponent("A", isDirectory: true)
        let bURL = directory.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: aURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bURL, withIntermediateDirectories: true)
        let a = SourceRecord(id: "scope-a", kind: local ? .local : .openSubsonic, name: "Source A",
                             location: local ? aURL.absoluteString : "https://a.invalid", createdAt: Date(timeIntervalSince1970: 1))
        let b = SourceRecord(id: "scope-b", kind: local ? .local : .openSubsonic, name: "Source B",
                             location: local ? bURL.absoluteString : "https://b.invalid", createdAt: Date(timeIntervalSince1970: 2))
        let first = TrackRecord(id: "scope-a-track", sourceID: a.id, albumID: "shared", title: "Common A", artist: "Common Artist",
                                album: "Common Album", year: 2000, genre: "Rock", duration: 120, remoteID: "a", remotePath: "Artist/Album/a.flac")
        let second = TrackRecord(id: "scope-b-track", sourceID: b.id, albumID: "shared", title: "Common B", artist: "common artist",
                                 album: "Common Album", year: 2000, genre: "Rock", duration: 120, remoteID: "b", remotePath: "Artist/Album/b.flac")
        try store.saveSource(a); try store.saveSource(b); try store.upsertTracks([first, second])
        let remoteOperation: RemoteCatalogOperation? = script.map { script in
            let operation: RemoteCatalogOperation = { source, receive in try await script.run(sourceID: source.id, receive: receive) }
            return operation
        }
        let scopedLoader: ScopedLibrarySnapshotLoader? = gate.map { gate in
            let loader: ScopedLibrarySnapshotLoader = { scope, store, sources in try await gate.load(scope: scope, store: store, sources: sources) }
            return loader
        }
        let model = AppModel(store: store, preferences: quietPreferences(), registerSystemControls: false,
                             localScan: { source, progress in
                                 if let scanGate { await scanGate.enter(sourceID: source.id) }
                                 return try await LibraryScanner().scan(source: source, metadataReader: { _ in AudioFileMetadata() }, progress: progress)
                             }, remoteCatalog: remoteOperation, scopedSnapshotLoader: scopedLoader)
        return Fixture(directory: directory, store: store, model: model, sourceA: a, sourceB: b, trackA: first, trackB: second)
    }
    private func quietPreferences() -> AppPreferences { var value = AppPreferences(); value.volume = 0; return value }
    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The expected all-source state was not published.")
        throw URLError(.timedOut)
    }
    private func requireRuns(_ script: AllCatalogScript, count: Int) async throws {
        for _ in 0..<150 { if await script.sourceIDs.count >= count { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("The remote catalog operation did not start."); throw URLError(.timedOut)
    }
    private func requireRequests(_ gate: AllSnapshotGate, count: Int) async throws {
        for _ in 0..<150 { if await gate.count >= count { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("The scoped snapshot loader did not start."); throw URLError(.timedOut)
    }
    private func requireScans(_ gate: AllScanGate, count: Int) async throws {
        for _ in 0..<150 { if await gate.sourceIDs.count >= count { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("The local source scanner did not start."); throw URLError(.timedOut)
    }
    private struct Fixture {
        let directory: URL
        let store: LibraryStore
        let model: AppModel
        let sourceA: SourceRecord
        let sourceB: SourceRecord
        let trackA: TrackRecord
        let trackB: TrackRecord
        @MainActor func cleanup() { model.cancelRefresh(); try? FileManager.default.removeItem(at: directory) }
    }
}

private actor AllSnapshotGate {
    private var holding = false
    private var requests: [(LibrarySnapshot, CheckedContinuation<LibrarySnapshot, Error>?)] = []
    var count: Int { requests.count }
    func hold() { holding = true }
    func load(scope: LibraryScope, store: LibraryStore, sources: [SourceRecord]) async throws -> LibrarySnapshot {
        let value = try await Task.detached { try LibrarySnapshot.build(scope: scope, tracks: store.tracks(scope: scope), sources: sources) }.value
        guard holding else { return value }
        return try await withCheckedThrowingContinuation { requests.append((value, $0)) }
    }
    func release(_ index: Int) {
        guard requests.indices.contains(index), let continuation = requests[index].1 else { return }
        requests[index].1 = nil; continuation.resume(returning: requests[index].0)
    }
    func releaseAll() { for index in requests.indices { release(index) } }
}

private actor AllCatalogScript {
    typealias Receiver = @Sendable ([TrackRecord], Int, Int?) async throws -> Void
    private struct Run { let sourceID: String; let receive: Receiver; var completion: CheckedContinuation<Void, Error>? }
    private var runs: [Run] = []
    var sourceIDs: [String] { runs.map(\.sourceID) }
    func run(sourceID: String, receive: @escaping Receiver) async throws {
        try await withCheckedThrowingContinuation { runs.append(Run(sourceID: sourceID, receive: receive, completion: $0)) }
    }
    func emit(_ tracks: [TrackRecord], run: Int) async throws { try await runs[run].receive(tracks, 1, 2) }
    func finish(_ run: Int, error: Error? = nil) {
        guard runs.indices.contains(run), let continuation = runs[run].completion else { return }
        runs[run].completion = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
    func finishAll() { for index in runs.indices { finish(index) } }
}

private actor AllScanGate {
    private var continuations: [CheckedContinuation<Void, Never>?] = []
    private(set) var sourceIDs: [String] = []
    func enter(sourceID: String) async {
        sourceIDs.append(sourceID)
        await withCheckedContinuation { continuations.append($0) }
    }
    func release(_ index: Int) {
        guard continuations.indices.contains(index), let continuation = continuations[index] else { return }
        continuations[index] = nil; continuation.resume()
    }
    func releaseAll() { for index in continuations.indices { release(index) } }
}
