import Foundation
import MacarokAudio
import MacarokCore

/// One prepared item owns its transport for its complete queued/playing lifetime.
/// A full upcoming stream never occupies the current stream's callback queue.
final class PreparedQueuePlayback: @unchecked Sendable {
    let url: URL?
    let stream: BufferedHTTPInputStream?
    let transport: SourceTransport?
    let renewedSource: SourceRecord?

    init(url: URL, renewedSource: SourceRecord? = nil) {
        self.url = url; self.renewedSource = renewedSource
        stream = nil; transport = nil
    }

    init(stream: BufferedHTTPInputStream, transport: SourceTransport) {
        self.stream = stream; self.transport = transport
        url = nil; renewedSource = nil
    }

    deinit { stream?.close(); transport?.invalidate() }

    @MainActor func install(on player: VLCPlaybackEngine, track: TrackRecord, buffer: Double?) {
        if let url {
            player.load(url: url, segmentStart: track.startTime ?? 0, segmentEnd: track.endTime,
                        bufferSeconds: buffer, durationHint: track.duration)
        } else if let stream {
            player.load(stream: stream, segmentStart: track.startTime ?? 0, segmentEnd: track.endTime,
                        bufferSeconds: buffer, durationHint: track.duration, supportsSeeking: { stream.supportsSeeking })
        }
    }

    @MainActor func installUpcoming(on player: VLCPlaybackEngine, token: UUID, track: TrackRecord, buffer: Double?) -> Bool {
        if let url {
            return player.setUpcoming(token: token, url: url, segmentStart: track.startTime ?? 0, segmentEnd: track.endTime,
                               bufferSeconds: buffer, durationHint: track.duration)
        } else if let stream {
            return player.setUpcoming(token: token, stream: stream, segmentStart: track.startTime ?? 0, segmentEnd: track.endTime,
                               bufferSeconds: buffer, durationHint: track.duration, supportsSeeking: { stream.supportsSeeking })
        }
        return false
    }
}

@MainActor
final class UpcomingPlaybackPreparation {
    let id: UUID
    let source: SourceRecord
    let track: TrackRecord
    let buffer: Double?
    var task: Task<Void, Never>?
    var resource: PreparedQueuePlayback?
    init(id: UUID, source: SourceRecord, track: TrackRecord, buffer: Double?) {
        self.id = id; self.source = source; self.track = track; self.buffer = buffer
    }
    func cancel() { task?.cancel(); task = nil; resource = nil }
}
