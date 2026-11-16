import Foundation
import MacarokCore
import MacarokMetadata
import XCTest
@testable import MacarokApp

@MainActor
final class RecordingIdentificationPreparationTests: XCTestCase {
    func testRelocatedDirectoryBookmarkReturnsTheReadableWholeFileOffMainActor() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Previous Music", isDirectory: true)
        let relocated = directory.appendingPathComponent("Current Music", isDirectory: true)
        let relative = "Artist/Album/Track.flac"
        let currentFile = relocated.appendingPathComponent(relative)
        try writeSyntheticFile(at: currentFile)
        let calls = IdentificationPreparationCalls()
        let worker = PlaybackPreparationWorker(environment: environment(calls: calls, target: relocated, isDirectory: true))
        let source = localSource(at: original)
        let model = model(source: source, worker: worker)
        let track = TrackRecord(sourceID: source.id, fileURL: original.appendingPathComponent(relative).absoluteString)

        let url = try await model.prepareIdentificationFile(for: track)

        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(track.url).path))
        XCTAssertEqual(url, currentFile)
        XCTAssertEqual(try Data(contentsOf: url), Data("Synthetic identification input".utf8))
        XCTAssertEqual(calls.count("resolve"), 1)
        XCTAssertEqual(calls.events.filter { $0.kind == "probe" }.map(\.url), [currentFile])
        XCTAssertFalse(calls.events.contains(where: \.mainThread))
        await worker.shutdown()
        XCTAssertEqual(calls.count("stop"), 1)
    }

    func testMovedExplicitFileReturnsItsRenamedBookmarkTarget() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Previous/Track.flac")
        let relocated = directory.appendingPathComponent("Current/Renamed.flac")
        try writeSyntheticFile(at: relocated)
        let calls = IdentificationPreparationCalls()
        let worker = PlaybackPreparationWorker(environment: environment(calls: calls, target: relocated, isDirectory: false))
        let source = localSource(at: original)
        let model = model(source: source, worker: worker)

        let url = try await model.prepareIdentificationFile(for: TrackRecord(sourceID: source.id, fileURL: original.absoluteString))

        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(url, relocated)
        XCTAssertEqual(calls.events.filter { $0.kind == "probe" }.map(\.url), [relocated])
        await worker.shutdown()
        XCTAssertEqual(calls.count("stop"), 1)
    }

    func testSourceRemovalOrReplacementDuringBookmarkResolutionCancelsTheResult() async throws {
        for removeSource in [true, false] {
            let directory = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("Track.flac")
            try writeSyntheticFile(at: file)
            let calls = IdentificationPreparationCalls()
            let gate = IdentificationResolutionGate()
            defer { gate.release() }
            let worker = PlaybackPreparationWorker(environment: environment(calls: calls, target: directory, isDirectory: true, gate: gate))
            let source = localSource(at: directory)
            let model = model(source: source, worker: worker)
            let track = TrackRecord(sourceID: source.id, fileURL: file.absoluteString)
            let request = Task { try await model.prepareIdentificationFile(for: track) }
            defer { request.cancel() }
            try await waitForResolution(gate)

            if removeSource { model.sources = [] }
            else {
                var replacement = source
                replacement.bookmarkData = Data([9])
                model.sources = [replacement]
            }
            gate.release()

            do {
                _ = try await request.value
                XCTFail("A removed or changed source must not return its obsolete identification URL.")
            } catch is CancellationError { }
            XCTAssertFalse(gate.timedOut)
            await worker.shutdown()
            XCTAssertEqual(calls.count("start"), calls.count("stop"))
        }
    }

    func testCancellationDuringBookmarkResolutionDoesNotAcquireSecurityAccess() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Track.flac")
        try writeSyntheticFile(at: file)
        let calls = IdentificationPreparationCalls()
        let gate = IdentificationResolutionGate()
        defer { gate.release() }
        let worker = PlaybackPreparationWorker(environment: environment(calls: calls, target: directory, isDirectory: true, gate: gate))
        let source = localSource(at: directory)
        let model = model(source: source, worker: worker)
        let track = TrackRecord(sourceID: source.id, fileURL: file.absoluteString)
        let request = Task { try await model.prepareIdentificationFile(for: track) }
        defer { request.cancel() }
        try await waitForResolution(gate)

        request.cancel()
        gate.release()

        do {
            _ = try await request.value
            XCTFail("Cancelling identification while a bookmark resolves must discard its URL.")
        } catch is CancellationError { }
        XCTAssertFalse(gate.timedOut)
        XCTAssertEqual(calls.count("resolve"), 1)
        XCTAssertEqual(calls.count("start"), 0)
        XCTAssertEqual(calls.count("probe"), 0)
        await worker.shutdown()
    }

    func testDelayedBookmarkRenewalPreservesRemovedOrReplacedPersistedSources() async throws {
        for removeSource in [true, false] {
            let directory = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("Track.flac")
            try writeSyntheticFile(at: file)
            let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
            try store.saveSource(localSource(at: directory))
            let source = try XCTUnwrap(store.sources().first)
            var changed = source
            changed.name = "Replacement source"
            changed.bookmarkData = Data([9])
            let replacement = changed
            let calls = IdentificationPreparationCalls()
            let worker = PlaybackPreparationWorker(environment: environment(calls: calls, target: directory,
                isDirectory: true, stale: true))
            let model = AppModel(store: store, preferences: AppPreferences(), registerSystemControls: false,
                                 playbackPreparation: worker)
            model.sources = [source]
            let gate = IdentificationResolutionGate()
            defer { gate.release() }
            let edit = Task {
                try await model.performLibraryWork { store in
                    gate.wait()
                    if removeSource { try store.deleteSource(id: source.id) }
                    else { try store.saveSource(replacement) }
                }
            }
            defer { edit.cancel() }
            try await waitForResolution(gate)

            let url = try await model.prepareIdentificationFile(for: TrackRecord(sourceID: source.id, fileURL: file.absoluteString))
            XCTAssertEqual(url, file)
            XCTAssertEqual(calls.count("renew"), 1)
            // Let the MainActor renewal task enqueue behind the held edit, then enqueue a
            // serialized read after it. The model intentionally still holds the old source.
            await Task.yield()
            let drain = Task { try await model.performLibraryWork { try $0.sources() } }
            await Task.yield()
            gate.release()
            try await edit.value
            let persisted = try await drain.value

            XCTAssertEqual(persisted, removeSource ? [] : [replacement],
                           "A delayed bookmark refresh must not recreate a deleted row or overwrite its replacement.")
            XCTAssertEqual(model.sources, [source])
            XCTAssertFalse(gate.timedOut)
            await worker.shutdown()
        }
    }

    func testMissingAndUnreadableFilesReturnTheExistingMissingFileError() async throws {
        for exists in [false, true] {
            let directory = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("Track.flac")
            if exists { try writeSyntheticFile(at: file) }
            let calls = IdentificationPreparationCalls()
            let worker = PlaybackPreparationWorker(environment: environment(calls: calls, target: directory,
                isDirectory: true, allowRead: !exists))
            let source = localSource(at: directory)
            let model = model(source: source, worker: worker)

            do {
                _ = try await model.prepareIdentificationFile(for: TrackRecord(sourceID: source.id, fileURL: file.absoluteString))
                XCTFail("Identification must not accept a missing or unreadable audio file.")
            } catch AppFailure.missingFile { }
            XCTAssertEqual(calls.events.filter { $0.kind == "probe" }.map(\.url), [file])
            await worker.shutdown()
            XCTAssertEqual(calls.count("stop"), 1)
        }
    }

    func testCUEAndRemoteTracksAreRejectedBeforeBookmarkOrFileResolution() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = IdentificationPreparationCalls()
        let worker = PlaybackPreparationWorker(environment: environment(calls: calls, target: directory, isDirectory: true))
        let local = localSource(at: directory)
        let remote = SourceRecord(id: "remote", kind: .openSubsonic, name: "Remote", location: "https://music.invalid", bookmarkData: Data([2]))
        let model = model(source: local, worker: worker)
        model.sources = [local, remote]
        let cue = TrackRecord(sourceID: local.id, fileURL: directory.appendingPathComponent("Album.flac").absoluteString,
                              startTime: 0, endTime: 60)

        do {
            _ = try await model.prepareIdentificationFile(for: cue)
            XCTFail("A virtual CUE segment must not identify its shared whole album.")
        } catch AudioIdentificationError.cueSegmentUnsupported { }
        do {
            _ = try await model.prepareIdentificationFile(for: TrackRecord(sourceID: remote.id, fileURL: "https://music.invalid/audio.flac"))
            XCTFail("Remote music must not enter local fingerprint preparation.")
        } catch AudioIdentificationError.localFileRequired { }
        do {
            _ = try await model.prepareIdentificationFile(for: TrackRecord(sourceID: local.id, fileURL: "https://music.invalid/audio.flac"))
            XCTFail("A remote URL in a local record must not reach bookmark or filesystem resolution.")
        } catch AppFailure.missingFile { }

        XCTAssertTrue(calls.events.isEmpty)
        await worker.shutdown()
    }

    private func model(source: SourceRecord, worker: PlaybackPreparationWorker) -> AppModel {
        let model = AppModel(preferences: AppPreferences(), registerSystemControls: false, playbackPreparation: worker)
        model.sources = [source]
        return model
    }

    private func localSource(at url: URL) -> SourceRecord {
        SourceRecord(id: "local", kind: .local, name: "Synthetic Music", location: url.absoluteString, bookmarkData: Data([1]))
    }

    private func environment(calls: IdentificationPreparationCalls, target: URL, isDirectory: Bool,
                             allowRead: Bool = true, gate: IdentificationResolutionGate? = nil,
                             stale: Bool = false) -> PlaybackPreparationEnvironment {
        PlaybackPreparationEnvironment(resolveBookmark: { _ in
            calls.record("resolve", url: target)
            gate?.wait()
            return (target, stale)
        }, makeBookmark: { url in
            calls.record("renew", url: url); return Data([2])
        }, startAccess: { url in
            calls.record("start", url: url); return true
        }, stopAccess: { url in calls.record("stop", url: url) }, isDirectory: { url in
            calls.record("directory", url: url); return isDirectory
        }, isReadableFile: { url in
            calls.record("probe", url: url)
            return allowRead && FileManager.default.isReadableFile(atPath: url.path)
        })
    }

    private func waitForResolution(_ gate: IdentificationResolutionGate) async throws {
        for _ in 0..<200 {
            if gate.entered { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The fake bookmark resolver did not start.")
        throw PreparationTestError.timeout
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokIdentificationPreparation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSyntheticFile(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Synthetic identification input".utf8).write(to: url)
    }

    private enum PreparationTestError: Error { case timeout }
}

private final class IdentificationPreparationCalls: @unchecked Sendable {
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

private final class IdentificationResolutionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var didEnter = false
    private var released = false
    private var didTimeOut = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return didEnter }
    var timedOut: Bool { condition.lock(); defer { condition.unlock() }; return didTimeOut }
    func wait() {
        condition.lock(); defer { condition.unlock() }
        didEnter = true
        let deadline = Date().addingTimeInterval(5)
        while !released {
            if !condition.wait(until: deadline) { didTimeOut = true; break }
        }
    }
    func release() {
        condition.lock(); defer { condition.unlock() }
        released = true
        condition.broadcast()
    }
}
