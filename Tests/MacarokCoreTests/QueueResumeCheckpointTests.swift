import Foundation
import MacarokCore
import XCTest

final class QueueResumeCheckpointTests: XCTestCase {
    func testResumeCheckpointLeavesLargeQueueBlobUntouchedAndNewQueueDiscardsIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokQueueCheckpoint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let ids = (0..<50_000).map { "track-\($0)" }
        try store.saveQueue(trackIDs: ids, currentIndex: 0, position: 0)
        let content = try XCTUnwrap(store.value(forKey: "playbackQueue"))
        try store.saveQueuePosition(currentIndex: 49_999, position: 243.75)
        XCTAssertEqual(try store.value(forKey: "playbackQueue"), content,
                       "A frequent resume update must not re-encode or replace the queue's large track-ID payload.")
        let checkpoint = try XCTUnwrap(store.value(forKey: "playbackResume"))
        XCTAssertLessThan(checkpoint.count, 128)
        let restored = try XCTUnwrap(store.loadQueue())
        XCTAssertEqual(restored.trackIDs, ids)
        XCTAssertEqual(restored.currentIndex, 49_999)
        XCTAssertEqual(restored.position, 243.75)
        try store.saveQueue(trackIDs: ["replacement"], currentIndex: 0, position: 2)
        XCTAssertNil(try store.value(forKey: "playbackResume"))
        XCTAssertEqual(try store.loadQueue()?.trackIDs, ["replacement"])
        XCTAssertEqual(try store.loadQueue()?.position, 2)
    }

    func testInvalidResumeValuesAreBoundedWhenRestoringExistingAndEmptyQueues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokQueueCheckpointBounds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try store.saveQueue(trackIDs: ["one", "two"], currentIndex: 0, position: 0)
        try store.saveQueuePosition(currentIndex: 99, position: .infinity)
        XCTAssertEqual(try store.loadQueue()?.currentIndex, 1)
        XCTAssertEqual(try store.loadQueue()?.position, 0)
        try store.saveQueuePosition(currentIndex: -10, position: -3)
        XCTAssertEqual(try store.loadQueue()?.currentIndex, 0)
        XCTAssertEqual(try store.loadQueue()?.position, 0)
        try store.saveQueue(trackIDs: [], currentIndex: 0, position: 0)
        try store.saveQueuePosition(currentIndex: 99, position: .nan)
        XCTAssertEqual(try store.loadQueue()?.trackIDs, [])
        XCTAssertEqual(try store.loadQueue()?.currentIndex, 0)
        XCTAssertEqual(try store.loadQueue()?.position, 0)
    }
}
