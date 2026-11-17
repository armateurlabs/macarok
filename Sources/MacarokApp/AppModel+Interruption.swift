import Foundation
import MacarokCore

extension AppModel {
    static let interruptionResumeLimit = 3

    /// A dropped connection reaches VLC as an early end of the track. Instead of skipping to the next
    /// entry, play the same entry again from where it stopped; listening history is not counted twice.
    func recoverInterruptedPlayback(at position: Double) {
        guard let id = currentQueueID, let track = currentTrack else { return }
        var recovery = interruptionRecovery.flatMap { $0.queueID == id ? $0 : nil } ?? (queueID: id, attempts: 0, position: position)
        // Progress since the last resume means that resume worked; a later drop gets a fresh budget.
        if position > recovery.position + 30 { recovery.attempts = 0 }
        recovery.position = position
        restorePosition = max(0, position)
        guard recovery.attempts < Self.interruptionResumeLimit else {
            interruptionRecovery = nil
            playbackIntentQueueID = nil
            fail("Playback interrupted", "The connection to the server was lost before the end of “\(track.title)”. Press Play to continue where it stopped.")
            return
        }
        recovery.attempts += 1
        interruptionRecovery = recovery
        status = "Connection lost. Resuming “\(track.title)” at \(position.playbackTime)…"
        let attempt = recovery.attempts, recorded = playRecorded, heard = heardSeconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(attempt)))
            guard let self, self.currentQueueID == id, self.interruptionRecovery?.attempts == attempt,
                  [.stopped, .failed].contains(self.player.state) else { return }
            self.playQueueItem(id, origin: .resumption)
            self.playRecorded = recorded; self.heardSeconds = heard
        }
    }
}
