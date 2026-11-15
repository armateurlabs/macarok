import CoreServices
import Foundation
import XCTest
@testable import MacarokApp

final class LocalFileChangeSuppressionTests: XCTestCase {
    func testSuppressesOnlyAnExactRecentPostWriteState() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let clock = SuppressionClock()
        let filter = LocalFileChangeSuppression(now: { clock.value })
        filter.recordWrites(urls: [fixture.file])
        let event = DirectoryChangeBatch(paths: [fixture.file.path], mustRescan: false)
        XCTAssertFalse(filter.shouldRescan(event))
        XCTAssertTrue(filter.shouldRescan(DirectoryChangeBatch(paths: [fixture.directory.path], mustRescan: false)),
                      "A directory-only event could hide an unrelated child change.")
        XCTAssertTrue(filter.shouldRescan(DirectoryChangeBatch(paths: [fixture.file.path], mustRescan: true)))
        clock.advance(11)
        XCTAssertTrue(filter.shouldRescan(event))
    }

    func testExternalSameSizeWriteOrAtomicReplacementCannotBeSuppressed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let filter = LocalFileChangeSuppression()
        let event = DirectoryChangeBatch(paths: [fixture.file.path], mustRescan: false)
        filter.recordWrites(urls: [fixture.file])
        let date = try XCTUnwrap(try fixture.file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try Data("other".utf8).write(to: fixture.file)
        // Even if an external editor preserves modification time and size, inode/ctime changes are relevant.
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fixture.file.path)
        XCTAssertTrue(filter.shouldRescan(event))
        filter.recordWrites(urls: [fixture.file])
        XCTAssertFalse(filter.shouldRescan(event))
        try Data("third".utf8).write(to: fixture.file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fixture.file.path)
        XCTAssertTrue(filter.shouldRescan(event))
        try FileManager.default.removeItem(at: fixture.file)
        XCTAssertTrue(filter.shouldRescan(event))
    }

    func testMixedBatchesAndUnrecognizedStagingPathsStillRescan() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let filter = LocalFileChangeSuppression()
        filter.recordWrites(urls: [fixture.file])
        let completedStaging = fixture.directory.appendingPathComponent(".macarok-\(UUID().uuidString).flac")
        XCTAssertFalse(filter.shouldRescan(DirectoryChangeBatch(paths: [fixture.file.path, completedStaging.path], mustRescan: false)))
        XCTAssertTrue(filter.shouldRescan(DirectoryChangeBatch(paths: [fixture.file.path, fixture.directory.appendingPathComponent("other.flac").path], mustRescan: false)))
        XCTAssertTrue(filter.shouldRescan(DirectoryChangeBatch(paths: [fixture.directory.appendingPathComponent(".macarok-not-a-uuid.flac").path], mustRescan: false)))
        XCTAssertTrue(filter.shouldRescan(DirectoryChangeBatch(paths: [fixture.directory.appendingPathComponent(".macarok-\(UUID().uuidString).mp3").path], mustRescan: false)))
        try Data("unrelated".utf8).write(to: fixture.directory.appendingPathComponent("new.flac"))
        XCTAssertTrue(filter.shouldRescan(DirectoryChangeBatch(paths: [completedStaging.path], mustRescan: false)),
                      "Changes in the recorded staging parent invalidate its atomic-write evidence.")
        XCTAssertTrue(filter.shouldRescan(DirectoryChangeBatch(paths: [], mustRescan: false)))
    }

    func testFSEventsRootAndDroppedHistoryFlagsForceRescan() {
        let path = "/synthetic/track.flac"
        let ordinary = DirectoryWatcher.changeBatch(paths: [path], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)])
        XCTAssertEqual(ordinary.paths, [path])
        XCTAssertFalse(ordinary.mustRescan)
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
                     kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagEventIdsWrapped,
                     kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagMount, kFSEventStreamEventFlagUnmount] {
            XCTAssertTrue(DirectoryWatcher.changeBatch(paths: [path], flags: [FSEventStreamEventFlags(flag)]).mustRescan)
        }
        XCTAssertTrue(DirectoryWatcher.changeBatch(paths: [path], flags: []).mustRescan)
        XCTAssertTrue(DirectoryWatcher.changeBatch(paths: [], flags: []).mustRescan)
    }

    private func makeFixture() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokFileSuppression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("track.flac")
        try Data("first".utf8).write(to: file)
        return (directory, file)
    }
}

private final class SuppressionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 100
    var value: TimeInterval { lock.withLock { instant } }
    func advance(_ seconds: TimeInterval) { lock.withLock { instant += seconds } }
}
