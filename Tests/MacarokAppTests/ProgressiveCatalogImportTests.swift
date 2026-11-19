import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

/// Gated catalogs exercise persistence and publication without credentials or a remote server.
@MainActor
final class ProgressiveCatalogImportTests: XCTestCase {
    func testFirstAlbumIsPersistedSearchableAndAddableBeforeImportFinishes() async throws {
        let script = CatalogScript()
        let fixture = try await makeFixture(script: script)
        defer { fixture.cleanup(); Task { await script.finishAll() } }
        let first = track("first", sourceID: fixture.sourceA.id, title: "Early Arrival")

        fixture.model.refresh()
        try await requireRuns(script, count: 1)
        try await script.emit([first], completed: 1, total: 2)

        try await expectEventually { fixture.model.tracks.contains { $0.id == first.id } }
        XCTAssertTrue(fixture.model.isRefreshing)
        XCTAssertEqual(try fixture.store.track(id: first.id)?.title, first.title)
        fixture.model.search = "Early Arrival"
        try await expectEventually { fixture.model.displayedTracks.map(\.id) == [first.id] }
        fixture.model.add([first])
        XCTAssertEqual(fixture.model.queue.map(\.track.id), [first.id])
        XCTAssertTrue(fixture.model.isRefreshing, "Browsing and queuing must work before the catalog completes.")
        await script.finish()
        try await expectEventually { !fixture.model.isRefreshing }
    }

    func testLaterFailureKeepsOldCacheAndEveryCommittedPartialAlbum() async throws {
        let script = CatalogScript()
        let fixture = try await makeFixture(script: script, seedOldTrack: true)
        defer { fixture.cleanup(); Task { await script.finishAll() } }
        let first = track("first", sourceID: fixture.sourceA.id)
        let second = track("second", sourceID: fixture.sourceA.id)

        fixture.model.refresh()
        try await requireRuns(script, count: 1)
        try await script.emit([first], completed: 1, total: 3)
        try await script.emit([second], completed: 2, total: 3)
        await script.finish(error: URLError(.networkConnectionLost))

        try await expectEventually { !fixture.model.isRefreshing }
        for id in [fixture.old.id, first.id, second.id] {
            XCTAssertEqual(try fixture.store.track(id: id)?.isAvailable, true)
        }
        try await expectEventually {
            Set(fixture.model.tracks.map(\.id)) == [fixture.old.id, first.id, second.id]
        }
        XCTAssertNotNil(fixture.model.message)
        let reopened = AppModel(store: fixture.store, preferences: AppPreferences(), registerSystemControls: false)
        await reopened.start()
        XCTAssertTrue(reopened.status.contains("incomplete"), "A partial cache must not be reported as fully imported after restart.")
        XCTAssertEqual(Set(reopened.tracks.map(\.id)), [fixture.old.id, first.id, second.id])
    }

    func testCancellationKeepsPartialAlbumsAndDoesNotReconcileMissingTracks() async throws {
        let script = CatalogScript()
        let fixture = try await makeFixture(script: script, seedOldTrack: true)
        defer { fixture.cleanup(); Task { await script.finishAll() } }
        let first = track("first", sourceID: fixture.sourceA.id)
        let second = track("second", sourceID: fixture.sourceA.id)

        fixture.model.refresh()
        try await requireRuns(script, count: 1)
        try await script.emit([first], completed: 1, total: 3)
        try await script.emit([second], completed: 2, total: 3)
        fixture.model.cancelRefresh()
        await script.finish()

        try await expectEventually { !fixture.model.isRefreshing }
        XCTAssertEqual(try fixture.store.track(id: fixture.old.id)?.isAvailable, true)
        XCTAssertEqual(try fixture.store.track(id: first.id)?.isAvailable, true)
        XCTAssertEqual(try fixture.store.track(id: second.id)?.isAvailable, true)
        try await expectEventually { fixture.model.tracks.contains { $0.id == second.id } }
        XCTAssertNil(fixture.model.message, "Cancellation must not display a refresh failure alert.")
    }

    func testSuccessfulCompletionReconcilesOnlyItsSourceAndPreservesUserData() async throws {
        let script = CatalogScript()
        let fixture = try await makeFixture(script: script, seedOldTrack: true)
        defer { fixture.cleanup(); Task { await script.finishAll() } }
        var kept = track("kept", sourceID: fixture.sourceA.id, title: "My Correction")
        kept.metadataLocked = true
        kept.addedAt = Date(timeIntervalSince1970: 100)
        try fixture.store.upsertTracks([kept])
        for _ in 0..<3 { try fixture.store.recordPlay(trackID: kept.id, at: Date(timeIntervalSince1970: 200)) }
        try fixture.store.setRating(trackID: kept.id, rating: 4)
        let playlist = try fixture.store.savePlaylist(name: "Keep References", trackIDs: [fixture.old.id, kept.id, fixture.other.id])
        var incoming = kept
        incoming.title = "Server Title"; incoming.metadataLocked = false
        let added = track("new", sourceID: fixture.sourceA.id)

        fixture.model.refresh()
        try await requireRuns(script, count: 1)
        try await script.emit([incoming, added], completed: 1, total: 1)
        XCTAssertEqual(try fixture.store.track(id: fixture.old.id)?.isAvailable, true,
                       "The previous cache stays usable until a complete successful import.")
        await script.finish()
        try await expectEventually { !fixture.model.isRefreshing }

        XCTAssertEqual(try fixture.store.track(id: fixture.old.id)?.isAvailable, false)
        XCTAssertEqual(try fixture.store.track(id: fixture.other.id)?.isAvailable, true)
        XCTAssertEqual(Set(try fixture.store.tracks(sourceID: fixture.sourceA.id).map(\.id)), [kept.id, added.id])
        let saved = try XCTUnwrap(fixture.store.track(id: kept.id))
        XCTAssertEqual(saved.title, "My Correction")
        XCTAssertEqual(saved.playCount, 3)
        XCTAssertEqual(saved.rating, 4)
        XCTAssertEqual(saved.lastPlayedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(saved.addedAt, kept.addedAt)
        XCTAssertEqual(try fixture.store.playlistTracks(id: playlist.id).map(\.id), [fixture.old.id, kept.id, fixture.other.id])
        let reopened = AppModel(store: fixture.store, preferences: AppPreferences(), registerSystemControls: false)
        await reopened.start()
        XCTAssertFalse(reopened.status.contains("incomplete"), "A successful complete import clears its incomplete marker.")
    }

    func testSourceSwitchNeverPublishesTheBackgroundSourcesTracks() async throws {
        let script = CatalogScript()
        let fixture = try await makeFixture(script: script, seedOldTrack: true)
        defer { fixture.cleanup(); Task { await script.finishAll() } }
        let first = track("first", sourceID: fixture.sourceA.id)
        let second = track("second", sourceID: fixture.sourceA.id)

        fixture.model.refresh()
        try await requireRuns(script, count: 1)
        try await script.emit([first], completed: 1, total: 2)
        fixture.model.sourceID = fixture.sourceB.id
        try await script.emit([second], completed: 2, total: 2)
        try await expectEventually { fixture.model.snapshotSourceID == fixture.sourceB.id && !fixture.model.isLoadingLibrary }
        XCTAssertEqual(fixture.model.sourceID, fixture.sourceB.id)
        XCTAssertEqual(fixture.model.tracks.map(\.id), [fixture.other.id])
        XCTAssertEqual(try fixture.store.track(id: second.id)?.sourceID, fixture.sourceA.id)

        await script.finish()
        try await expectEventually { !fixture.model.isRefreshing }
        XCTAssertEqual(fixture.model.tracks.map(\.id), [fixture.other.id])
        XCTAssertEqual(try fixture.store.track(id: fixture.old.id)?.isAvailable, false)
    }

    func testStaleGenerationCannotOverwriteOrReconcileANewerImport() async throws {
        let script = CatalogScript()
        let fixture = try await makeFixture(script: script, seedOldTrack: true)
        defer { fixture.cleanup(); Task { await script.finishAll() } }
        let old = track("shared", sourceID: fixture.sourceA.id, title: "Old Generation")
        let fresh = track("shared", sourceID: fixture.sourceA.id, title: "Fresh Generation")
        let otherFresh = track("fresh-only", sourceID: fixture.sourceA.id)
        let stale = track("stale-only", sourceID: fixture.sourceA.id)

        fixture.model.refresh()
        try await requireRuns(script, count: 1)
        try await script.emit([old], completed: 1, total: 2, run: 0)
        fixture.model.refresh()
        try await requireRuns(script, count: 2)
        try await script.emit([fresh, otherFresh], completed: 1, total: 2, run: 1)
        do { try await script.emit([old, stale], completed: 2, total: 2, run: 0) }
        catch is CancellationError { }
        await script.finish(run: 0)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(fixture.model.isRefreshing)
        XCTAssertEqual(try fixture.store.track(id: fresh.id)?.title, fresh.title)
        XCTAssertNil(try fixture.store.track(id: stale.id))
        XCTAssertEqual(try fixture.store.track(id: fixture.old.id)?.isAvailable, true)
        await script.finish(run: 1)
        try await expectEventually { !fixture.model.isRefreshing }
        XCTAssertEqual(Set(fixture.model.tracks.map(\.id)), [fresh.id, otherFresh.id])
    }

    func testAutomaticRefreshImportsAServerOnlyWhenItsFingerprintChangesAndStaysQuiet() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokAutomaticRefresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("test.sqlite"))
        let source = SourceRecord(id: "auto-\(UUID().uuidString)", kind: .openSubsonic, name: "Server", location: "https://a.invalid")
        try store.saveSource(source)
        let cached = track("cached", sourceID: source.id), added = track("added", sourceID: source.id)
        try store.upsertTracks([cached])
        let runs = ImportRuns()
        var fingerprint: String? = "scan-1"
        let model = AppModel(store: store, preferences: AppPreferences(), registerSystemControls: false,
                             remoteCatalog: { _, receive in await runs.record(); try await receive([cached, added], 1, 1) },
                             remoteFingerprint: { _ in fingerprint })
        await model.start()
        model.sourceID = source.id
        try await expectEventually { model.snapshotSourceID == source.id && !model.isLoadingLibrary }

        // No fingerprint has been stored yet, so the first check imports the catalog.
        await model.refreshSourcesAutomatically(includeLocal: false)
        try await expectEventually { !model.isRefreshing }
        let firstRuns = await runs.count
        XCTAssertEqual(firstRuns, 1)
        XCTAssertEqual(Set(model.tracks.map(\.id)), [cached.id, added.id])
        XCTAssertNil(model.message, "An automatic refresh must not present alerts.")

        let revision = model.libraryRevision
        await model.refreshSourcesAutomatically(includeLocal: false)
        XCTAssertFalse(model.isRefreshing, "An unchanged server must not be read again.")
        let unchangedRuns = await runs.count
        XCTAssertEqual(unchangedRuns, 1)

        fingerprint = "scan-2"
        await model.refreshSourcesAutomatically(includeLocal: false)
        try await expectEventually { !model.isRefreshing }
        let changedRuns = await runs.count
        XCTAssertEqual(changedRuns, 2)
        XCTAssertEqual(model.libraryRevision, revision, "A quiet import that changed nothing must not republish the library.")

        fingerprint = nil
        try store.setValue(Data([1]), forKey: AppModel.catalogImportKey(source.id))
        await model.refreshSourcesAutomatically(includeLocal: false)
        try await expectEventually { !model.isRefreshing }
        let resumedRuns = await runs.count
        XCTAssertEqual(resumedRuns, 3, "An interrupted import resumes even when the server cannot describe its catalog.")
    }

    func testRefreshingACachedCatalogPublishesOnceAtTheEndIncludingTheSearch() async throws {
        let script = CatalogScript()
        let fixture = try await makeFixture(script: script, seedOldTrack: true)
        defer { fixture.cleanup(); Task { await script.finishAll() } }
        let arrival = track("arrival", sourceID: fixture.sourceA.id, title: "Late Arrival")
        fixture.model.search = "arrival"
        try await expectEventually { !fixture.model.isSearching }
        XCTAssertTrue(fixture.model.displayedTracks.isEmpty)
        let revision = fixture.model.libraryRevision

        fixture.model.refresh()
        try await requireRuns(script, count: 1)
        try await script.emit([fixture.old, arrival], completed: 1, total: 2)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(fixture.model.libraryRevision, revision, "A cached catalog must stay as it is while it refreshes.")
        XCTAssertTrue(fixture.model.displayedTracks.isEmpty)

        await script.finish()
        try await expectEventually { !fixture.model.isRefreshing && fixture.model.tracks.contains { $0.id == arrival.id } }
        try await expectEventually { fixture.model.displayedTracks.map(\.id) == [arrival.id] }
    }

    private func makeFixture(script: CatalogScript, seedOldTrack: Bool = false) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokProgressiveImport-\(UUID().uuidString)")
        let store = try LibraryStore(url: directory.appendingPathComponent("test.sqlite"))
        let sourceA = SourceRecord(id: "catalog-a-\(UUID().uuidString)", kind: .openSubsonic,
                                   name: "Catalog A", location: "https://a.invalid", createdAt: Date(timeIntervalSince1970: 1))
        let sourceB = SourceRecord(id: "catalog-b-\(UUID().uuidString)", kind: .openSubsonic,
                                   name: "Catalog B", location: "https://b.invalid", createdAt: Date(timeIntervalSince1970: 2))
        try store.saveSource(sourceA); try store.saveSource(sourceB)
        let old = track("cached-old", sourceID: sourceA.id)
        let other = track("other-source", sourceID: sourceB.id)
        try store.upsertTracks((seedOldTrack ? [old] : []) + [other])
        var preferences = AppPreferences(); preferences.volume = 0
        let model = AppModel(store: store, preferences: preferences, registerSystemControls: false,
                             remoteCatalog: { source, receive in try await script.run(sourceID: source.id, receive: receive) })
        await model.start()
        model.sourceID = sourceA.id
        try await expectEventually { model.snapshotSourceID == sourceA.id && !model.isLoadingLibrary }
        return Fixture(directory: directory, store: store, model: model, sourceA: sourceA, sourceB: sourceB, old: old, other: other)
    }

    private func track(_ id: String, sourceID: String, title: String? = nil) -> TrackRecord {
        TrackRecord(id: "\(sourceID)-\(id)", sourceID: sourceID, title: title ?? id,
                    artist: "Test Artist", album: "Album \(id)", duration: 120,
                    remoteID: id, format: "FLAC")
    }

    private func requireRuns(_ script: CatalogScript, count: Int,
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        let ready = await script.waitForRuns(count)
        XCTAssertTrue(ready, "The catalog operation did not start.", file: file, line: line)
        guard ready else { throw URLError(.timedOut) }
    }

    private func expectEventually(file: StaticString = #filePath, line: UInt = #line,
                                  _ condition: @MainActor () throws -> Bool) async throws {
        for _ in 0..<100 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The progressive catalog did not publish the expected state within two seconds.", file: file, line: line)
    }

    private struct Fixture {
        let directory: URL
        let store: LibraryStore
        let model: AppModel
        let sourceA: SourceRecord
        let sourceB: SourceRecord
        let old: TrackRecord
        let other: TrackRecord
        @MainActor func cleanup() { model.cancelRefresh(); try? FileManager.default.removeItem(at: directory) }
    }
}

private actor ImportRuns {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor CatalogScript {
    typealias Receiver = @Sendable ([TrackRecord], Int, Int?) async throws -> Void
    private struct Run {
        let sourceID: String
        let receive: Receiver
        var completion: CheckedContinuation<Void, Error>?
    }
    private var runs: [Run] = []

    func run(sourceID: String, receive: @escaping Receiver) async throws {
        try await withCheckedThrowingContinuation { continuation in
            runs.append(Run(sourceID: sourceID, receive: receive, completion: continuation))
        }
    }

    func emit(_ tracks: [TrackRecord], completed: Int, total: Int?, run: Int = 0) async throws {
        try await runs[run].receive(tracks, completed, total)
    }

    func finish(run: Int = 0, error: Error? = nil) {
        guard runs.indices.contains(run), let completion = runs[run].completion else { return }
        runs[run].completion = nil
        if let error { completion.resume(throwing: error) }
        else { completion.resume() }
    }

    func finishAll() { for index in runs.indices { finish(run: index) } }

    func waitForRuns(_ count: Int) async -> Bool {
        for _ in 0..<100 {
            if runs.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
