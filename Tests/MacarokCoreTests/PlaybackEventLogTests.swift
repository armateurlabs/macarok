import Foundation
import XCTest
@testable import MacarokCore

final class PlaybackEventLogTests: XCTestCase {
    func testRingKeepsLatestEventsInChronologicalOrderAndCountsOverwrites() {
        var log = PlaybackEventLog(capacity: 3)
        for index in 1...8 { log.append(.phaseChanged, metrics: .init(position: Double(index))) }
        XCTAssertEqual(log.entries.map(\.sequence), [6, 7, 8])
        XCTAssertEqual(log.entries.map(\.metrics.position), [6, 7, 8])
        XCTAssertEqual(log.droppedEntries, 5)
        XCTAssertEqual(log.capacity, 3)
    }

    func testClearPreservesUniqueSequenceNumbersAndCapacityIsBounded() {
        var log = PlaybackEventLog(capacity: 0)
        XCTAssertEqual(log.capacity, 1)
        log.append(.failed); log.append(.watchdog)
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertEqual(log.droppedEntries, 0)
        XCTAssertEqual(log.append(.completed).sequence, 3)
        XCTAssertEqual(PlaybackEventLog(capacity: Int.max).capacity, 2_000)
    }

    func testNumericSanitizationMakesInvalidSamplesExportable() throws {
        let metrics = PlaybackEventLog.Metrics(position: .nan, duration: -.infinity, bufferedBytes: -8,
            bufferCapacityBytes: -1, underrunCount: -2, readerWaitSeconds: .infinity, installationCount: -10,
            installationSeconds: .nan, transitionSeconds: -1, secondsWithoutProgress: .infinity)
        XCTAssertNil(metrics.position); XCTAssertNil(metrics.duration); XCTAssertNil(metrics.readerWaitSeconds)
        XCTAssertNil(metrics.installationSeconds); XCTAssertNil(metrics.transitionSeconds)
        XCTAssertNil(metrics.secondsWithoutProgress)
        XCTAssertEqual(metrics.bufferedBytes, 0); XCTAssertEqual(metrics.bufferCapacityBytes, 0)
        XCTAssertEqual(metrics.underrunCount, 0); XCTAssertEqual(metrics.installationCount, 0)
        var log = PlaybackEventLog()
        log.append(.failed, metrics: metrics, timestamp: Date(timeIntervalSince1970: .nan))
        let data = try JSONEncoder().encode(log.export(at: Date(timeIntervalSince1970: .infinity)))
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(log.entries.first?.timestamp, Date(timeIntervalSince1970: 0))
    }

    func testExportIsVersionedBoundedAndContainsOnlyTypedDiagnosticFields() throws {
        var log = PlaybackEventLog(capacity: 2)
        let id = UUID()
        log.append(.occurrenceStarted, occurrenceID: id, phase: .opening, media: .podcast)
        log.append(.underrun, occurrenceID: id, phase: .buffering, media: .podcast,
            metrics: .init(position: 40, bufferedBytes: 0, bufferCapacityBytes: 4096, underrunCount: 1))
        log.append(.watchdog, occurrenceID: id, phase: .playing, media: .podcast,
            metrics: .init(secondsWithoutProgress: 12, reason: .progressStalled, transportIsAdvancing: true))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(log.export(at: Date(timeIntervalSince1970: 100)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["droppedEntries"] as? Int, 1)
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events[0].keys), ["sequence", "timestamp", "occurrenceID", "kind", "phase", "media", "metrics"])
        let text = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["https://", "file://", "password", "credential", "tracktitle", "sourcename", "filepath", "localizeddescription"] {
            XCTAssertFalse(text.contains(forbidden))
        }
        XCTAssertTrue(log.entries.last?.metrics.summary.contains("Playback stopped making progress") == true)
    }
}
