import Foundation

public struct ListeningSessionUpdate: Sendable {
    public var beganPlaying: Bool
    public var submission: LastFMSubmission?
}

/// A deterministic accumulator. Position jumps never stand in for listening time.
public struct ListeningSession: Sendable {
    public let occurrenceID: String
    public private(set) var track: LastFMTrackSnapshot
    public private(set) var heardSeconds: Double = 0
    public private(set) var startedAt: Date?
    public private(set) var hasQualified = false
    private var previousTime: TimeInterval?
    private var previouslyPlaying = false
    private var previousPosition: Double?

    public init(track: LastFMTrackSnapshot, occurrenceID: String = UUID().uuidString) {
        self.track = track; self.occurrenceID = occurrenceID
    }

    public mutating func sample(isPlaying: Bool, isBuffering: Bool, position: Double,
                                duration: Double, monotonic: TimeInterval, date: Date) -> ListeningSessionUpdate {
        if duration.isFinite, duration > 0 { track.duration = duration }
        let active = isPlaying && !isBuffering
        let began = active && startedAt == nil
        if began { startedAt = date }
        if let previousTime, monotonic.isFinite, monotonic >= previousTime, previouslyPlaying {
            let elapsed = monotonic - previousTime
            // A discontinuous position sample means a seek, rather than that much music being heard.
            let delta = previousPosition.map { position - $0 }
            if delta == nil || !active || (delta!.isFinite && delta! >= -0.1 && delta! <= elapsed + 2) {
                heardSeconds += elapsed
            }
        }
        previousTime = monotonic.isFinite ? monotonic : nil
        previousPosition = position.isFinite ? position : nil
        previouslyPlaying = active
        return ListeningSessionUpdate(beganPlaying: began, submission: qualifiedSubmission())
    }

    /// Call before a seek or sleep; subsequent samples establish a new timing baseline.
    public mutating func suspend() { previousTime = nil; previousPosition = nil; previouslyPlaying = false }

    public mutating func suspend(monotonic: TimeInterval, date: Date) -> LastFMSubmission? {
        let submission = finish(monotonic: monotonic, date: date)
        suspend()
        return submission
    }

    public mutating func seek(monotonic: TimeInterval, date: Date) -> LastFMSubmission? {
        let wasPlaying = previouslyPlaying
        let submission = finish(monotonic: monotonic, date: date)
        previousTime = monotonic.isFinite ? monotonic : nil
        previousPosition = nil
        previouslyPlaying = wasPlaying
        return submission
    }

    public mutating func finish(monotonic: TimeInterval, date: Date) -> LastFMSubmission? {
        sample(isPlaying: false, isBuffering: false, position: previousPosition ?? 0,
               duration: track.duration, monotonic: monotonic, date: date).submission
    }

    private mutating func qualifiedSubmission() -> LastFMSubmission? {
        guard !hasQualified, let startedAt, track.isEligible,
              track.duration == 0 || track.duration > 30 else { return nil }
        let threshold = track.duration > 0 ? min(track.duration / 2, 240) : 240
        guard heardSeconds >= threshold else { return nil }
        hasQualified = true
        return LastFMSubmission(id: occurrenceID, track: track, startedAt: startedAt)
    }
}
