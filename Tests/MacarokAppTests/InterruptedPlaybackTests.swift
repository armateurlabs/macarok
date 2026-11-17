import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

@MainActor
final class InterruptedPlaybackTests: XCTestCase {
    func testAnInterruptedTrackResumesWhereItStoppedAndGivesUpAfterRepeatedDrops() {
        var preferences = AppPreferences()
        preferences.volume = 0
        let model = AppModel(preferences: preferences, registerSystemControls: false)
        let track = TrackRecord(id: "song", sourceID: "server", title: "Long Song", duration: 400)
        model.queue = [QueueItem(track: track), QueueItem(track: TrackRecord(id: "next", sourceID: "server", title: "Next"))]
        model.currentQueueID = model.queue[0].id
        model.playRecorded = true

        model.recoverInterruptedPlayback(at: 201)
        XCTAssertEqual(model.currentQueueID, model.queue[0].id, "An interruption never advances to the next entry.")
        XCTAssertEqual(model.restorePosition, 201)
        XCTAssertEqual(model.interruptionRecovery?.attempts, 1)
        XCTAssertTrue(model.status.contains("Resuming"))

        model.recoverInterruptedPlayback(at: 203); model.recoverInterruptedPlayback(at: 204)
        XCTAssertEqual(model.interruptionRecovery?.attempts, 3)
        model.recoverInterruptedPlayback(at: 260)
        XCTAssertEqual(model.interruptionRecovery?.attempts, 1, "Progress after a resume gives a later drop a fresh budget.")

        model.recoverInterruptedPlayback(at: 261); model.recoverInterruptedPlayback(at: 262)
        model.recoverInterruptedPlayback(at: 263)
        XCTAssertNil(model.interruptionRecovery)
        XCTAssertEqual(model.message?.title, "Playback interrupted")
        XCTAssertEqual(model.restorePosition, 263, "Play continues from the last position.")
        XCTAssertEqual(model.currentQueueID, model.queue[0].id)
    }
}
