import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

/// Held snapshots prove that navigation and queue work do not wait for catalog preparation.
@MainActor
final class LibraryResponsivenessTests: XCTestCase {
    func testNavigationAndMainActorHeartbeatContinueWhileSnapshotIsPending() async throws {
        let gate = SnapshotGate()
        let fixture = try await makeFixture(gate: gate)
        defer { fixture.cleanup(); Task { await gate.releaseAll() } }
        await gate.holdNextLoads()

        fixture.model.reloadLibrary()
        try await requireRequests(gate, count: 1)
        XCTAssertTrue(fixture.model.isLoadingLibrary)
        let heartbeat = MainActorHeartbeat()
        let navigation = Task { @MainActor in
            for view in LibraryView.allCases {
                fixture.model.libraryView = view
                _ = fixture.model.albums.count
                _ = fixture.model.artists.count
                _ = fixture.model.visibleAlbums.count
                heartbeat.count += 1
                await Task.yield()
            }
        }
        await navigation.value
        fixture.model.add([fixture.trackA])
        await fixture.model.flushQueue()

        XCTAssertEqual(heartbeat.count, LibraryView.allCases.count)
        XCTAssertTrue(fixture.model.isLoadingLibrary, "Navigation must run while the background request is still held.")
        XCTAssertEqual(fixture.model.queue.map(\.track.id), [fixture.trackA.id])
        XCTAssertEqual(try fixture.store.loadQueue()?.trackIDs, [fixture.trackA.id])
        await gate.release(0)
        try await expectEventually { !fixture.model.isLoadingLibrary }
    }

    func testSameSourceReloadsCoalesceBehindOneWorkerAndFinishWithFreshData() async throws {
        let gate = SnapshotGate()
        let fixture = try await makeFixture(gate: gate)
        defer { fixture.cleanup(); Task { await gate.releaseAll() } }
        await gate.holdNextLoads()

        fixture.model.reloadLibrary()
        try await requireRequests(gate, count: 1)
        var updated = fixture.trackA
        updated.title = "Fresh Snapshot"
        try fixture.store.upsertTracks([updated])
        fixture.model.reloadLibrary()
        fixture.model.reloadLibrary()
        try await Task.sleep(for: .milliseconds(80))
        let pendingCount = await gate.requestCount
        XCTAssertEqual(pendingCount, 1, "Repeated reloads must not start concurrent workers for the same source.")

        await gate.release(0)
        try await requireRequests(gate, count: 2)
        XCTAssertTrue(fixture.model.isLoadingLibrary)
        await gate.release(1)
        try await expectEventually { fixture.model.tracks.first?.title == updated.title && !fixture.model.isLoadingLibrary }
        try await Task.sleep(for: .milliseconds(80))
        let completedCount = await gate.requestCount
        XCTAssertEqual(completedCount, 2, "A burst of reloads should produce one follow-up snapshot.")
        XCTAssertEqual(fixture.model.tracks.first?.title, "Fresh Snapshot")
        XCTAssertEqual(fixture.model.snapshotSourceID, fixture.sourceA.id)
        XCTAssertNil(fixture.model.message)
    }

    func testSourceSwitchHidesOldDataAndRejectsALateOtherSourceSnapshot() async throws {
        let gate = SnapshotGate()
        let fixture = try await makeFixture(gate: gate)
        defer { fixture.cleanup(); Task { await gate.releaseAll() } }
        await gate.holdNextLoads()

        fixture.model.sourceID = fixture.sourceB.id
        XCTAssertTrue(fixture.model.tracks.isEmpty)
        XCTAssertTrue(fixture.model.albums.isEmpty)
        try await requireRequests(gate, count: 1)
        fixture.model.sourceID = fixture.sourceA.id
        try await requireRequests(gate, count: 2)
        await gate.release(1)
        try await expectEventually { fixture.model.snapshotSourceID == fixture.sourceA.id && !fixture.model.isLoadingLibrary }
        await gate.release(0)
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(fixture.model.sourceID, fixture.sourceA.id)
        XCTAssertEqual(fixture.model.snapshotSourceID, fixture.sourceA.id)
        XCTAssertEqual(fixture.model.tracks.map(\.id), [fixture.trackA.id])
    }

    func testAnObsoleteLoadFailureCannotFinishOrAlertForTheCurrentRequest() async throws {
        let gate = SnapshotGate()
        let fixture = try await makeFixture(gate: gate)
        defer { fixture.cleanup(); Task { await gate.releaseAll() } }
        await gate.holdNextLoads()

        fixture.model.sourceID = fixture.sourceB.id
        try await requireRequests(gate, count: 1)
        fixture.model.sourceID = fixture.sourceA.id
        try await requireRequests(gate, count: 2)
        await gate.fail(0)
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(fixture.model.isLoadingLibrary)
        XCTAssertNil(fixture.model.message)
        await gate.release(1)
        try await expectEventually { !fixture.model.isLoadingLibrary }
        XCTAssertEqual(fixture.model.tracks.map(\.id), [fixture.trackA.id])
    }

    private func makeFixture(gate: SnapshotGate) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokResponsiveness-\(UUID().uuidString)")
        let store = try LibraryStore(url: directory.appendingPathComponent("test.sqlite"))
        let sourceA = SourceRecord(id: "responsive-a-\(UUID().uuidString)", kind: .openSubsonic,
                                   name: "Source A", location: "https://a.invalid", createdAt: Date(timeIntervalSince1970: 1))
        let sourceB = SourceRecord(id: "responsive-b-\(UUID().uuidString)", kind: .openSubsonic,
                                   name: "Source B", location: "https://b.invalid", createdAt: Date(timeIntervalSince1970: 2))
        let trackA = TrackRecord(id: "track-a", sourceID: sourceA.id, title: "Original Snapshot", artist: "Artist A", album: "Album A", year: 2005)
        let trackB = TrackRecord(id: "track-b", sourceID: sourceB.id, title: "Other Source", artist: "Artist B", album: "Album B", year: 2026)
        try store.saveSource(sourceA); try store.saveSource(sourceB)
        try store.upsertTracks([trackA, trackB])
        let model = AppModel(store: store, preferences: AppPreferences(), registerSystemControls: false,
                             snapshotLoader: { sourceID, store, sources in
                                 try await gate.load(sourceID: sourceID, store: store, sources: sources)
                             })
        await model.start()
        return Fixture(directory: directory, store: store, model: model, sourceA: sourceA, sourceB: sourceB, trackA: trackA)
    }

    private func requireRequests(_ gate: SnapshotGate, count: Int) async throws {
        let ready = await gate.waitForRequests(count)
        XCTAssertTrue(ready, "The background loader did not start.")
        if !ready { throw URLError(.timedOut) }
    }

    private func expectEventually(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The expected library snapshot was not published within two seconds.")
    }

    private struct Fixture {
        let directory: URL
        let store: LibraryStore
        let model: AppModel
        let sourceA: SourceRecord
        let sourceB: SourceRecord
        let trackA: TrackRecord
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }
}

@MainActor
private final class MainActorHeartbeat {
    var count = 0
}

private actor SnapshotGate {
    private struct Request {
        let snapshot: LibrarySnapshot
        var continuation: CheckedContinuation<LibrarySnapshot, Error>?
    }
    private var holding = false
    private var requests: [Request] = []

    var requestCount: Int { requests.count }

    func holdNextLoads() { holding = true }

    func load(sourceID: String, store: LibraryStore, sources: [SourceRecord]) async throws -> LibrarySnapshot {
        let snapshot = try await Task.detached {
            try LibrarySnapshot.build(sourceID: sourceID, tracks: store.tracks(sourceID: sourceID), sources: sources)
        }.value
        guard holding else { return snapshot }
        return try await withCheckedThrowingContinuation { continuation in
            requests.append(Request(snapshot: snapshot, continuation: continuation))
        }
    }

    func release(_ index: Int) {
        guard requests.indices.contains(index), let continuation = requests[index].continuation else { return }
        requests[index].continuation = nil
        continuation.resume(returning: requests[index].snapshot)
    }

    func fail(_ index: Int) {
        guard requests.indices.contains(index), let continuation = requests[index].continuation else { return }
        requests[index].continuation = nil
        continuation.resume(throwing: URLError(.cannotLoadFromNetwork))
    }

    func releaseAll() { for index in requests.indices { release(index) } }

    func waitForRequests(_ count: Int) async -> Bool {
        for _ in 0..<100 {
            if requests.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
