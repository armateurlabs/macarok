import Foundation

/// Pure progress monitoring. The caller supplies a monotonic clock and performs any user-visible recovery.
public struct PlaybackWatchdog: Sendable {
    public enum Phase: String, Codable, CaseIterable, Sendable {
        case preparing, opening, buffering, playing, paused, stopped, failed
        public var title: String { rawValue.capitalized }
        var isActive: Bool { self == .opening || self == .buffering || self == .playing }
    }
    public enum Reason: String, Codable, Sendable {
        case openingTimedOut, bufferingTimedOut, progressStalled
        public var title: String {
            switch self {
            case .openingTimedOut: "Playback did not start"
            case .bufferingTimedOut: "Buffering did not complete"
            case .progressStalled: "Playback stopped making progress"
            }
        }
    }
    public struct Configuration: Sendable {
        public var playingTimeout: TimeInterval
        public var liveTimeout: TimeInterval
        public var openingTimeout: TimeInterval
        public var bufferingTimeout: TimeInterval
        public var seekGrace: TimeInterval
        public var maximumSampleGap: TimeInterval
        public var minimumPositionAdvance: Double
        public init(playingTimeout: TimeInterval = 12, liveTimeout: TimeInterval = 30,
                    openingTimeout: TimeInterval = 45, bufferingTimeout: TimeInterval = 30,
                    seekGrace: TimeInterval = 10, maximumSampleGap: TimeInterval = 5,
                    minimumPositionAdvance: Double = 0.25) {
            self.playingTimeout = Self.positive(playingTimeout, fallback: 12)
            self.liveTimeout = Self.positive(liveTimeout, fallback: 30)
            self.openingTimeout = Self.positive(openingTimeout, fallback: 45)
            self.bufferingTimeout = Self.positive(bufferingTimeout, fallback: 30)
            self.seekGrace = Self.positive(seekGrace, fallback: 10)
            self.maximumSampleGap = Self.positive(maximumSampleGap, fallback: 5)
            self.minimumPositionAdvance = Self.positive(minimumPositionAdvance, fallback: 0.25)
        }
        private static func positive(_ value: Double, fallback: Double) -> Double { value.isFinite && value > 0 ? value : fallback }
    }
    public struct Sample: Sendable {
        public let occurrenceID: UUID?
        public let monotonicTime: TimeInterval
        public let phase: Phase
        public let position: Double?
        public let isLive: Bool
        public let isSeeking: Bool
        public let isSuspended: Bool
        /// Prefer actual played audio buffers, especially for streams without a reliable position clock.
        public let audioOutputCounter: UInt64?
        /// Diagnostic evidence only: incoming bytes must never conceal a frozen decoder.
        public let transportProgressCounter: UInt64?
        /// Extends startup/buffering deadlines for an explicitly configured large prebuffer.
        public let expectedBufferSeconds: TimeInterval?
        public init(occurrenceID: UUID?, monotonicTime: TimeInterval, phase: Phase, position: Double?,
                    isLive: Bool = false, isSeeking: Bool = false, isSuspended: Bool = false,
                    audioOutputCounter: UInt64? = nil, transportProgressCounter: UInt64? = nil,
                    expectedBufferSeconds: TimeInterval? = nil) {
            self.occurrenceID = occurrenceID; self.monotonicTime = monotonicTime; self.phase = phase
            self.position = position.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            self.isLive = isLive; self.isSeeking = isSeeking; self.isSuspended = isSuspended
            self.audioOutputCounter = audioOutputCounter; self.transportProgressCounter = transportProgressCounter
            self.expectedBufferSeconds = expectedBufferSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        public var hasProgressSignal: Bool { position != nil || audioOutputCounter != nil }
    }
    public struct Incident: Equatable, Sendable {
        public let occurrenceID: UUID
        public let reason: Reason
        public let secondsWithoutProgress: TimeInterval
        public let isLive: Bool
        public let transportIsAdvancing: Bool
    }

    public let configuration: Configuration
    private var occurrence: UUID?
    private var lastPhase: Phase?
    private var lastSampleTime: TimeInterval?
    private var progressAt: TimeInterval?
    private var positionAnchor: Double?
    private var outputCounter: UInt64?
    private var transportCounter: UInt64?
    private var transportAdvancedAt: TimeInterval?
    private var seekGraceUntil: TimeInterval?
    private var reported = false
    private var hasEnteredPlaying = false

    public init(configuration: Configuration = Configuration()) { self.configuration = configuration }
    public mutating func reset() { self = Self(configuration: configuration) }

    /// An explicit seek may finish between one-second samples; record it immediately as well as sampling isSeeking.
    public mutating func markSeek(occurrenceID: UUID, monotonicTime: TimeInterval) {
        guard monotonicTime.isFinite, monotonicTime >= 0 else { return }
        if occurrence != occurrenceID { reset(); occurrence = occurrenceID }
        lastSampleTime = monotonicTime; progressAt = monotonicTime
        seekGraceUntil = monotonicTime + configuration.seekGrace
        positionAnchor = nil; outputCounter = nil
    }

    public mutating func sample(_ sample: Sample) -> Incident? {
        guard let id = sample.occurrenceID else { reset(); return nil }
        if occurrence != id { reset(); occurrence = id }
        let now = sample.monotonicTime
        guard now.isFinite, now >= 0 else { resetObservations(); return nil }
        let interrupted = lastSampleTime.map { now < $0 || now - $0 > configuration.maximumSampleGap } ?? true
        let resumed = lastPhase.map { !$0.isActive && sample.phase.isActive } ?? true
        // Startup can legitimately use most of the opening deadline. Give the first playing
        // observation its own progress window, without allowing repeated phase flapping to do so.
        let firstPlaying = sample.phase == .playing && !hasEnteredPlaying
        if firstPlaying { hasEnteredPlaying = true }
        if interrupted || resumed || firstPlaying { establishBaseline(sample) }
        lastSampleTime = now; lastPhase = sample.phase

        if sample.isSuspended || !sample.phase.isActive {
            establishBaseline(sample); seekGraceUntil = nil
            return nil
        }
        if sample.isSeeking {
            establishBaseline(sample); seekGraceUntil = now + configuration.seekGrace
            return nil
        }
        if let until = seekGraceUntil, now < until {
            establishBaseline(sample)
            return nil
        }
        seekGraceUntil = nil

        var advanced = false
        if let position = sample.position {
            if let anchor = positionAnchor {
                if position - anchor >= configuration.minimumPositionAdvance { advanced = true; positionAnchor = position }
                else if anchor - position >= 2 {
                    // A discontinuity may be an acknowledged backward seek whose transient flag was missed.
                    establishBaseline(sample); seekGraceUntil = now + configuration.seekGrace
                    return nil
                }
            } else { positionAnchor = position; advanced = true }
        }
        if let output = sample.audioOutputCounter {
            if let previous = outputCounter, output != previous { advanced = true }
            else if outputCounter == nil { advanced = true }
            outputCounter = output
        }
        if let transport = sample.transportProgressCounter {
            if let previous = transportCounter, transport > previous { transportAdvancedAt = now }
            transportCounter = transport
        }
        if advanced { progressAt = now }
        // Some live/unknown-duration formats have no observable clock. Absence of a signal is not evidence of silence.
        if sample.phase == .playing && !sample.hasProgressSignal { progressAt = now; return nil }
        guard !reported, let lastProgress = progressAt else { return nil }
        let elapsed = max(0, now - lastProgress)
        let reason: Reason
        let timeout: TimeInterval
        let configuredWait = sample.expectedBufferSeconds.map { $0 + configuration.seekGrace } ?? 0
        switch sample.phase {
        case .opening: reason = .openingTimedOut; timeout = max(configuration.openingTimeout, configuredWait)
        case .buffering: reason = .bufferingTimedOut; timeout = max(configuration.bufferingTimeout, configuredWait)
        case .playing: reason = .progressStalled; timeout = sample.isLive ? configuration.liveTimeout : configuration.playingTimeout
        default: return nil
        }
        guard elapsed >= timeout else { return nil }
        reported = true
        return Incident(occurrenceID: id, reason: reason, secondsWithoutProgress: elapsed, isLive: sample.isLive,
                        transportIsAdvancing: transportAdvancedAt.map { now - $0 <= configuration.maximumSampleGap } ?? false)
    }

    private mutating func establishBaseline(_ sample: Sample) {
        progressAt = sample.monotonicTime; positionAnchor = sample.position
        outputCounter = sample.audioOutputCounter; transportCounter = sample.transportProgressCounter
    }
    private mutating func resetObservations() {
        lastPhase = nil; lastSampleTime = nil; progressAt = nil; positionAnchor = nil
        outputCounter = nil; transportCounter = nil; transportAdvancedAt = nil; seekGraceUntil = nil
    }
}
