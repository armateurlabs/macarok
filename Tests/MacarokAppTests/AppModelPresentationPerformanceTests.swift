import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

@MainActor
final class AppModelPresentationPerformanceTests: XCTestCase {
    func testTypedPatchesUpdateRankingsAndQueueWithoutReloadingTheCatalog() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let model = fixture.model, original = fixture.trackA
        model.add([original, original, fixture.trackA2])
        model.currentQueueID = model.queue[1].id
        model.selectedQueueIDs = [model.queue[2].id]
        model.restorePosition = 73.5
        let ids = model.queue.map(\.id), selected = model.selectedQueueIDs
        let initialLoads = await fixture.loader.loadCount
        let initialAlbums = model.albums.map(\.presentationID)
        let initialYears = model.yearGroups.map(\.id)

        model.rate(original, value: 4)
        try await eventually { model.tracks.first(where: { $0.id == original.id })?.rating == 4 }
        let playedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try fixture.store.recordPlay(trackID: original.id, at: playedAt)
        let played = try XCTUnwrap(fixture.store.track(id: original.id))
        model.patchLibraryTracks([played], kind: .history)
        try fixture.store.cacheRemoteArtwork(sourceID: original.sourceID, albumID: original.albumID,
                                            coverArtID: "cover-a", path: "/synthetic/cached-cover.png")
        model.patchLibraryTracks(try fixture.store.albumTracks(sourceID: original.sourceID, albumID: original.albumID), kind: .artwork)
        try await eventually {
            model.currentTrack?.rating == 4 && model.currentTrack?.playCount == 1 &&
                model.currentTrack?.artworkPath == "/synthetic/cached-cover.png"
        }
        await model.waitForLibraryLoad()

        let finalLoads = await fixture.loader.loadCount
        XCTAssertEqual(finalLoads, initialLoads, "Rating, history, and cover changes must not request a new SQL catalog snapshot.")
        XCTAssertEqual(model.albums.map(\.presentationID), initialAlbums)
        XCTAssertEqual(model.yearGroups.map(\.id), initialYears)
        XCTAssertEqual(model.mostPlayedTracks.first?.id, original.id)
        XCTAssertEqual(model.recentlyPlayed.first?.lastPlayedAt, playedAt)
        XCTAssertEqual(model.mostPlayedAlbums.first?.id, original.albumID)
        XCTAssertEqual(model.mostPlayedArtists.first?.name, original.albumArtist)
        XCTAssertEqual(model.queue.map(\.id), ids)
        XCTAssertEqual(model.currentQueueID, ids[1])
        XCTAssertEqual(model.currentIndex, 1)
        XCTAssertEqual(model.selectedQueueIDs, selected)
        XCTAssertEqual(model.restorePosition, 73.5)
        XCTAssertEqual(model.player.position, 0)
        XCTAssertEqual(model.player.state, .stopped)
        XCTAssertTrue(model.queue.prefix(2).allSatisfy { $0.track.rating == 4 && $0.track.playCount == 1 })
        XCTAssertTrue(model.queue.allSatisfy { $0.track.artworkPath == "/synthetic/cached-cover.png" })
    }

    func testHeldSnapshotKeepsNewerTypedFieldsWithoutRollingBackScanMetadata() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup(); Task { await fixture.loader.releaseAll() } }
        let model = fixture.model, original = fixture.trackA
        model.add([original]); model.currentQueueID = model.queue[0].id; model.restorePosition = 48
        let queueID = model.currentQueueID
        var scanned = original
        scanned.title = "New title from a rescan"
        try fixture.store.updateTrackMetadata(scanned)
        await fixture.loader.holdNextLoads()
        let initialLoads = await fixture.loader.loadCount
        model.reloadLibrary()
        try await waitForLoad(fixture.loader, count: initialLoads + 1)
        XCTAssertTrue(model.isLoadingLibrary)

        try fixture.store.setRating(trackID: original.id, rating: 5)
        var staleRatingPayload = original
        staleRatingPayload.rating = 5
        model.patchLibraryTracks([staleRatingPayload], kind: .rating)
        try fixture.store.recordPlay(trackID: original.id, at: Date(timeIntervalSince1970: 1_800_000_010))
        let history = try XCTUnwrap(fixture.store.track(id: original.id))
        model.patchLibraryTracks([history], kind: .history)
        try fixture.store.cacheRemoteArtwork(sourceID: original.sourceID, albumID: original.albumID,
                                            coverArtID: "cover-a", path: "/synthetic/latest-cover.png")
        let artwork = try XCTUnwrap(fixture.store.track(id: original.id))
        model.patchLibraryTracks([artwork], kind: .artwork)
        try await eventually { model.currentTrack?.rating == 5 && model.currentTrack?.playCount == 1 }
        await fixture.loader.releaseAll()
        await model.waitForLibraryLoad()

        let visible = try XCTUnwrap(model.tracks.first { $0.id == original.id })
        XCTAssertEqual(visible.title, scanned.title, "A typed patch may not replace freshly indexed title/artist fields.")
        XCTAssertEqual(visible.rating, 5)
        XCTAssertEqual(visible.playCount, 1)
        XCTAssertEqual(visible.artworkPath, "/synthetic/latest-cover.png")
        XCTAssertEqual(model.currentTrack?.title, scanned.title)
        XCTAssertEqual(model.currentQueueID, queueID)
        XCTAssertEqual(model.restorePosition, 48)
        XCTAssertNil(model.message)
    }

    func testPatchesKeepQueuedTrackFreshWhileAnotherSourceIsBrowsed() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let model = fixture.model, original = fixture.trackA
        model.add([original, original]); model.currentQueueID = model.queue[1].id
        model.restorePosition = 91
        let ids = model.queue.map(\.id)
        model.libraryScope = .source(fixture.sourceB.id)
        await model.waitForLibraryLoad()
        let initialLoads = await fixture.loader.loadCount
        XCTAssertEqual(model.tracks.map(\.id), [fixture.trackB.id])

        try fixture.store.setRating(trackID: original.id, rating: 3)
        model.patchLibraryTracks([try XCTUnwrap(fixture.store.track(id: original.id))], kind: .rating)
        try fixture.store.recordPlay(trackID: original.id, at: Date(timeIntervalSince1970: 1_800_000_020))
        model.patchLibraryTracks([try XCTUnwrap(fixture.store.track(id: original.id))], kind: .history)
        try fixture.store.cacheRemoteArtwork(sourceID: original.sourceID, albumID: original.albumID,
                                            coverArtID: "cover-a", path: "/synthetic/other-scope-cover.png")
        model.patchLibraryTracks([try XCTUnwrap(fixture.store.track(id: original.id))], kind: .artwork)
        try await eventually {
            model.currentTrack?.rating == 3 && model.currentTrack?.playCount == 1 &&
                model.currentTrack?.artworkPath == "/synthetic/other-scope-cover.png"
        }
        await model.waitForLibraryLoad()

        XCTAssertEqual(model.libraryScope, .source(fixture.sourceB.id))
        XCTAssertEqual(model.tracks.map(\.id), [fixture.trackB.id])
        let finalLoads = await fixture.loader.loadCount
        XCTAssertEqual(finalLoads, initialLoads)
        XCTAssertEqual(model.queue.map(\.id), ids)
        XCTAssertTrue(model.queue.allSatisfy { $0.track.rating == 3 && $0.track.playCount == 1 })
        XCTAssertEqual(model.currentQueueID, ids[1])
        XCTAssertEqual(model.restorePosition, 91)
    }

    func testLargeQueueUsesEntryIdentityAndKeepsCurrentLookupResponsiveAfterReordering() {
        let model = AppModel(preferences: AppPreferences(), registerSystemControls: false)
        model.sources = [SourceRecord(id: "music", kind: .openSubsonic, name: "Music", location: "https://music.invalid"),
                         SourceRecord(id: "radio", kind: .radio, name: "Radio", location: "")]
        let tracks = (0..<100).map { TrackRecord(id: "repeated-\($0)", sourceID: $0 == 99 ? "radio" : "music", title: "Track \($0)") }
        model.queue = (0..<50_000).map { QueueItem(track: tracks[$0 % tracks.count]) }
        let currentID = model.queue[49_999].id
        model.currentQueueID = currentID
        let started = ProcessInfo.processInfo.systemUptime
        var total = 0
        for _ in 0..<2_000 {
            total += model.currentIndex ?? 0
            XCTAssertEqual(model.currentTrack?.id, "repeated-99")
            XCTAssertTrue(model.currentIsRadio)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertEqual(total, 49_999 * 2_000)
        XCTAssertLessThan(elapsed, 0.5, "Current-entry lookup must remain bounded when the same tracks appear many times.")
        model.queue.reverse()
        XCTAssertEqual(model.currentQueueID, currentID)
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertEqual(model.currentTrack?.id, "repeated-99")
        model.queue.removeFirst()
        XCTAssertNil(model.currentIndex)
        XCTAssertNil(model.currentTrack)
    }

    func testNewerPositionCheckpointCannotDiscardAnOlderPendingContentSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokQueueCheckpointOrdering-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try store.saveQueue(trackIDs: ["old"], currentIndex: 0, position: 0)
        let worker = LibraryBackgroundWorker()
        // Actor mailbox ordering must not be inferred from the order unstructured tasks were created.
        try await worker.saveQueuePosition(store: store, currentIndex: 1, position: 37, revision: 2)
        try await worker.saveQueue(store: store, trackIDs: ["new-first", "new-second"], currentIndex: 0, position: 0, revision: 1)
        let first = try XCTUnwrap(store.loadQueue())
        XCTAssertEqual(first.trackIDs, ["new-first", "new-second"])
        XCTAssertEqual(first.currentIndex, 1)
        XCTAssertEqual(first.position, 37)
        try await worker.saveQueue(store: store, trackIDs: ["final"], currentIndex: 0, position: 5, revision: 3)
        try await worker.saveQueuePosition(store: store, currentIndex: 1, position: 99, revision: 2)
        let final = try XCTUnwrap(store.loadQueue())
        XCTAssertEqual(final.trackIDs, ["final"])
        XCTAssertEqual(final.currentIndex, 0)
        XCTAssertEqual(final.position, 5)
    }

    private func makeFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokPresentationPatches-\(UUID().uuidString)")
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let sourceA = SourceRecord(id: "patch-a", kind: .openSubsonic, name: "A", location: "https://a.invalid", createdAt: Date(timeIntervalSince1970: 1))
        let sourceB = SourceRecord(id: "patch-b", kind: .openSubsonic, name: "B", location: "https://b.invalid", createdAt: Date(timeIntervalSince1970: 2))
        let trackA = TrackRecord(id: "patch-track-a", sourceID: sourceA.id, albumID: "album-a", title: "Original A", artist: "Artist A", album: "Album A", year: 2020,
                                 genre: "Ambient", remotePath: "Artist A/Album A/first.flac", coverArtID: "cover-a", format: "FLAC")
        var trackA2 = trackA
        trackA2.id = "patch-track-a2"; trackA2.title = "Second A"; trackA2.remotePath = "Artist A/Album A/second.flac"
        let trackB = TrackRecord(id: "patch-track-b", sourceID: sourceB.id, title: "Other source", artist: "Artist B", album: "Album B")
        try store.saveSource(sourceA); try store.saveSource(sourceB); try store.upsertTracks([trackA, trackA2, trackB])
        let loader = PresentationSnapshotLoader()
        let model = AppModel(store: store, preferences: AppPreferences(), registerSystemControls: false,
                             snapshotLoader: { sourceID, store, sources in try await loader.load(sourceID: sourceID, store: store, sources: sources) })
        await model.start(); await model.waitForLibraryLoad()
        return Fixture(directory: directory, store: store, model: model, loader: loader,
                       sourceB: sourceB, trackA: trackA, trackA2: trackA2, trackB: trackB)
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate())
    }

    private func waitForLoad(_ loader: PresentationSnapshotLoader, count: Int) async throws {
        let deadline = Date().addingTimeInterval(4)
        while await loader.loadCount < count, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let loaded = await loader.loadCount
        XCTAssertGreaterThanOrEqual(loaded, count)
    }

    private struct Fixture {
        let directory: URL
        let store: LibraryStore
        let model: AppModel
        let loader: PresentationSnapshotLoader
        let sourceB: SourceRecord
        let trackA: TrackRecord, trackA2: TrackRecord, trackB: TrackRecord
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }
}

private actor PresentationSnapshotLoader {
    private(set) var loadCount = 0
    private var holdsLoads = false
    private var held: [(LibrarySnapshot, CheckedContinuation<LibrarySnapshot, Never>)] = []
    func holdNextLoads() { holdsLoads = true }
    func releaseAll() {
        holdsLoads = false
        let pending = held; held.removeAll()
        for (snapshot, continuation) in pending { continuation.resume(returning: snapshot) }
    }
    func load(sourceID: String, store: LibraryStore, sources: [SourceRecord]) async throws -> LibrarySnapshot {
        let snapshot = try await Task.detached(priority: .utility) {
            try LibrarySnapshot.build(sourceID: sourceID, tracks: store.tracks(sourceID: sourceID, ordered: false), sources: sources)
        }.value
        loadCount += 1
        if holdsLoads {
            return await withCheckedContinuation { held.append((snapshot, $0)) }
        }
        return snapshot
    }
}
