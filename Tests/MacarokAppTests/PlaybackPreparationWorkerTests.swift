import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

final class PlaybackPreparationWorkerTests: XCTestCase {
    @MainActor
    func testSourceResolutionRunsOffMainAndSharesAccessWithPlaybackPreparation() async throws {
        let root = URL(fileURLWithPath: "/music", isDirectory: true)
        let file = root.appendingPathComponent("Track.flac")
        let calls = PreparationCalls()
        let worker = PlaybackPreparationWorker(environment: environment(calls: calls, resolvedRoot: root,
            readable: [file.path], directory: true, stale: true))
        let source = SourceRecord(id: "local", kind: .local, name: "Music", location: root.absoluteString, bookmarkData: Data([1]))
        let resolved = try await worker.resolveSource(source)
        XCTAssertEqual(resolved.url, root)
        XCTAssertEqual(resolved.renewedSource?.bookmarkData, Data([2]))
        let track = TrackRecord(sourceID: source.id, fileURL: file.absoluteString)
        let prepared = try await worker.prepare(source: try XCTUnwrap(resolved.renewedSource), track: track)
        XCTAssertEqual(prepared.url, file)
        XCTAssertEqual(calls.count("resolve"), 1)
        XCTAssertEqual(calls.count("start"), 1)
        XCTAssertFalse(calls.events.contains { $0.mainThread }, "Source access for scans, watchers, and editors must stay off MainActor too.")
        await worker.shutdown()
        XCTAssertEqual(calls.count("stop"), 1)
    }

    func testCancelledSourceResolutionNeverAcquiresAnAccessScope() async throws {
        let calls = PreparationCalls()
        let root = URL(fileURLWithPath: "/music", isDirectory: true)
        let worker = PlaybackPreparationWorker(environment: environment(calls: calls, resolvedRoot: root, readable: [], directory: true))
        let source = SourceRecord(id: "local", kind: .local, name: "Music", location: root.absoluteString, bookmarkData: Data([1]))
        let gate = PreparationGate()
        let task = Task {
            await gate.wait()
            return try await worker.resolveSource(source)
        }
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("A cancelled watcher or scan must not resolve its source.") }
        catch is CancellationError { }
        XCTAssertTrue(calls.events.isEmpty)
        await worker.shutdown()
    }

    @MainActor
    func testLocalFileChecksRunOffMainActorAndMissingFilesProduceTheExistingError() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Track.wav")
        try Data([0]).write(to: url)
        let calls = PreparationCalls()
        var environment = PlaybackPreparationEnvironment.live
        let readable = environment.isReadableFile
        environment.isReadableFile = { url in calls.record("probe", url: url); return readable(url) }
        let worker = PlaybackPreparationWorker(environment: environment)
        let source = SourceRecord(id: "local", kind: .local, name: "Music", location: directory.absoluteString)
        let track = TrackRecord(sourceID: source.id, fileURL: url.absoluteString)
        let prepared = try await worker.prepare(source: source, track: track)
        XCTAssertEqual(prepared.url, url)
        XCTAssertNil(prepared.renewedSource)
        XCTAssertFalse(calls.events.contains { $0.mainThread }, "Bookmark and file preparation must not run on MainActor.")
        try FileManager.default.removeItem(at: url)
        do { _ = try await worker.prepare(source: source, track: track); XCTFail("A missing audio file must not be installed in VLC.") }
        catch AppFailure.missingFile { }
        await worker.shutdown()
    }

    func testRelocatedDirectoryBookmarkRenewsOnceAndRetainsAccessAcrossPrefetches() async throws {
        let original = URL(fileURLWithPath: "/previous/Music", isDirectory: true)
        let relocated = URL(fileURLWithPath: "/current/Music", isDirectory: true)
        let firstURL = relocated.appendingPathComponent("Artist/Album/First.flac")
        let secondURL = relocated.appendingPathComponent("Artist/Album/Second.flac")
        let calls = PreparationCalls()
        let worker = PlaybackPreparationWorker(environment: environment(calls: calls, resolvedRoot: relocated,
            readable: [firstURL.path, secondURL.path], directory: true, stale: true))
        let source = SourceRecord(id: "local", kind: .local, name: "Music", location: original.absoluteString, bookmarkData: Data([1]))
        let first = TrackRecord(sourceID: source.id, fileURL: original.appendingPathComponent("Artist/Album/First.flac").absoluteString)
        let second = TrackRecord(sourceID: source.id, fileURL: original.appendingPathComponent("Artist/Album/Second.flac").absoluteString)
        let prepared = try await worker.prepare(source: source, track: first)
        XCTAssertEqual(prepared.url, firstURL)
        let renewed = try XCTUnwrap(prepared.renewedSource)
        XCTAssertEqual(renewed.bookmarkData, Data([2]))
        XCTAssertEqual(renewed.location, source.location, "Renewing a bookmark must not change indexed relative identities.")
        let preparedSecond = try await worker.prepare(source: renewed, track: second)
        XCTAssertEqual(preparedSecond.url, secondURL)
        XCTAssertEqual(calls.count("resolve"), 1)
        XCTAssertEqual(calls.count("start"), 1)
        XCTAssertEqual(calls.count("renew"), 1)
        XCTAssertEqual(calls.count("stop"), 0, "Preparing a next track must not end access still needed by the current track.")
        await worker.invalidate(sourceIDs: ["another-source"])
        XCTAssertEqual(calls.count("stop"), 0)
        await worker.invalidate(sourceIDs: [source.id])
        XCTAssertEqual(calls.count("stop"), 1)
        await worker.shutdown()
        XCTAssertEqual(calls.count("stop"), 1)
    }

    func testMovedExplicitAudioFileUsesBookmarkTargetInsteadOfTheStaleRecordedURL() async throws {
        let original = URL(fileURLWithPath: "/previous/Track.flac")
        let relocated = URL(fileURLWithPath: "/current/Renamed.flac")
        let calls = PreparationCalls()
        let worker = PlaybackPreparationWorker(environment: environment(calls: calls, resolvedRoot: relocated,
            readable: [relocated.path], directory: false))
        let source = SourceRecord(id: "file", kind: .local, name: "Track", location: original.absoluteString, bookmarkData: Data([1]))
        let track = TrackRecord(sourceID: source.id, fileURL: original.absoluteString)
        let prepared = try await worker.prepare(source: source, track: track)
        XCTAssertEqual(prepared.url, relocated)
        await worker.shutdown()
        XCTAssertEqual(calls.count("stop"), 1)
    }

    func testClearingOrReplacingBookmarkInvalidatesTheOldSecurityScope() async throws {
        let root = URL(fileURLWithPath: "/music", isDirectory: true)
        let file = root.appendingPathComponent("Track.flac")
        let calls = PreparationCalls()
        let worker = PlaybackPreparationWorker(environment: environment(calls: calls, resolvedRoot: root,
            readable: [file.path], directory: true))
        var source = SourceRecord(id: "local", kind: .local, name: "Music", location: root.absoluteString, bookmarkData: Data([1]))
        let track = TrackRecord(sourceID: source.id, fileURL: file.absoluteString)
        _ = try await worker.prepare(source: source, track: track)
        source.bookmarkData = nil
        _ = try await worker.prepare(source: source, track: track)
        XCTAssertEqual(calls.count("start"), 2)
        XCTAssertEqual(calls.count("stop"), 1)
        XCTAssertEqual(calls.count("resolve"), 1)
        await worker.shutdown()
        XCTAssertEqual(calls.count("stop"), 2)
    }

    func testRejectsRemoteOrMismatchedTrackBeforeAnyFileSystemWork() async throws {
        let calls = PreparationCalls()
        let root = URL(fileURLWithPath: "/music", isDirectory: true)
        let worker = PlaybackPreparationWorker(environment: environment(calls: calls, resolvedRoot: root, readable: [], directory: true))
        let source = SourceRecord(id: "local", kind: .local, name: "Music", location: root.absoluteString)
        do {
            _ = try await worker.prepare(source: source, track: TrackRecord(sourceID: "other", fileURL: "file:///music/Track.flac"))
            XCTFail("A prepared file must retain its actual source identity.")
        } catch AppFailure.missingSource { }
        do {
            _ = try await worker.prepare(source: source, track: TrackRecord(sourceID: source.id, fileURL: "https://music.invalid/track.flac"))
            XCTFail("HTTP tracks use the source transport instead of local file preparation.")
        } catch AppFailure.missingFile { }
        XCTAssertTrue(calls.events.isEmpty)
        await worker.shutdown()
    }

    func testAlreadyCancelledPreparationDoesNotAcquireSecurityAccess() async throws {
        let calls = PreparationCalls()
        let root = URL(fileURLWithPath: "/music", isDirectory: true)
        let worker = PlaybackPreparationWorker(environment: environment(calls: calls, resolvedRoot: root, readable: [], directory: true))
        let source = SourceRecord(id: "local", kind: .local, name: "Music", location: root.absoluteString)
        let gate = PreparationGate()
        let task = Task {
            await gate.wait()
            return try await worker.prepare(source: source, track: TrackRecord(sourceID: source.id, fileURL: "file:///music/Track.flac"))
        }
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("Obsolete preparation must not perform filesystem work.") }
        catch is CancellationError { }
        XCTAssertTrue(calls.events.isEmpty)
        await worker.shutdown()
    }

    private func environment(calls: PreparationCalls, resolvedRoot: URL, readable: Set<String>, directory: Bool, stale: Bool = false) -> PlaybackPreparationEnvironment {
        PlaybackPreparationEnvironment(resolveBookmark: { _ in calls.record("resolve", url: resolvedRoot); return (resolvedRoot, stale) },
            makeBookmark: { url in calls.record("renew", url: url); return Data([2]) },
            startAccess: { url in calls.record("start", url: url); return true },
            stopAccess: { url in calls.record("stop", url: url) },
            isDirectory: { url in calls.record("directory", url: url); return directory },
            isReadableFile: { url in calls.record("probe", url: url); return readable.contains(url.path) })
    }

    private func temporaryFolder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokPlaybackPreparation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class PreparationCalls: @unchecked Sendable {
    struct Event { let kind: String; let url: URL; let mainThread: Bool }
    private let lock = NSLock()
    private var values: [Event] = []
    func record(_ kind: String, url: URL) {
        lock.lock(); defer { lock.unlock() }
        values.append(Event(kind: kind, url: url, mainThread: Thread.isMainThread))
    }
    var events: [Event] { lock.lock(); defer { lock.unlock() }; return values }
    func count(_ kind: String) -> Int { events.filter { $0.kind == kind }.count }
}

private actor PreparationGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { if !opened { await withCheckedContinuation { waiter = $0 } } }
    func open() { opened = true; waiter?.resume(); waiter = nil }
}
