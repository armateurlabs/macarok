import Foundation

/// A fixed-capacity, session-only log with a deliberately closed, privacy-safe vocabulary.
/// Never place track titles, source names, URLs, paths, credentials, or arbitrary error descriptions here.
public struct PlaybackEventLog: Sendable {
    public enum Kind: String, Codable, Sendable {
        case occurrenceStarted, phaseChanged, installation, upcomingPrepared, upcomingCancelled, nativeHandoff
        case seek, underrun, completed, failed, watchdog, monitoringUnavailable
        public var title: String {
            switch self {
            case .occurrenceStarted: "Playback requested"
            case .phaseChanged: "State changed"
            case .installation: "Player installed"
            case .upcomingPrepared: "Next entry prepared"
            case .upcomingCancelled: "Next entry preparation cancelled"
            case .nativeHandoff: "Native track handoff"
            case .seek: "Seek requested"
            case .underrun: "Stream reader waited"
            case .completed: "Playback completed"
            case .failed: "Playback failed"
            case .watchdog: "Playback watchdog"
            case .monitoringUnavailable: "Progress signal unavailable"
            }
        }
        public var isWarning: Bool { self == .underrun || self == .watchdog || self == .monitoringUnavailable }
    }
    public enum MediaKind: String, Codable, Sendable {
        case localFile, remoteMusic, podcast, radio, unknown
        public var title: String {
            switch self {
            case .localFile: "Local file"
            case .remoteMusic: "Remote music"
            case .podcast: "Podcast"
            case .radio: "Internet radio"
            case .unknown: "Unknown"
            }
        }
    }
    public struct Metrics: Codable, Equatable, Sendable {
        public let position: Double?
        public let duration: Double?
        public let playedAudioBuffers: UInt64?
        public let decodedAudio: UInt64?
        public let readBytes: UInt64?
        public let bufferedBytes: Int?
        public let bufferCapacityBytes: Int?
        public let underrunCount: Int?
        public let readerWaitSeconds: Double?
        public let installationCount: Int?
        public let installationSeconds: Double?
        public let transitionSeconds: Double?
        public let secondsWithoutProgress: Double?
        public let reason: PlaybackWatchdog.Reason?
        public let transportIsAdvancing: Bool?
        public init(position: Double? = nil, duration: Double? = nil, playedAudioBuffers: UInt64? = nil,
                    decodedAudio: UInt64? = nil, readBytes: UInt64? = nil, bufferedBytes: Int? = nil,
                    bufferCapacityBytes: Int? = nil, underrunCount: Int? = nil, readerWaitSeconds: Double? = nil,
                    installationCount: Int? = nil, installationSeconds: Double? = nil,
                    transitionSeconds: Double? = nil, secondsWithoutProgress: Double? = nil,
                    reason: PlaybackWatchdog.Reason? = nil, transportIsAdvancing: Bool? = nil) {
            self.position = Self.finite(position); self.duration = Self.finite(duration)
            self.playedAudioBuffers = playedAudioBuffers; self.decodedAudio = decodedAudio; self.readBytes = readBytes
            self.bufferedBytes = bufferedBytes.map { max(0, $0) }; self.bufferCapacityBytes = bufferCapacityBytes.map { max(0, $0) }
            self.underrunCount = underrunCount.map { max(0, $0) }; self.readerWaitSeconds = Self.finite(readerWaitSeconds)
            self.installationCount = installationCount.map { max(0, $0) }; self.installationSeconds = Self.finite(installationSeconds)
            self.transitionSeconds = Self.finite(transitionSeconds); self.secondsWithoutProgress = Self.finite(secondsWithoutProgress)
            self.reason = reason; self.transportIsAdvancing = transportIsAdvancing
        }
        private static func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        public var summary: String {
            var fields: [String] = []
            if let reason { fields.append(reason.title) }
            if let position { fields.append(String(format: "position %.2f s", position)) }
            if let secondsWithoutProgress { fields.append(String(format: "no progress %.1f s", secondsWithoutProgress)) }
            if let bufferedBytes { fields.append("buffer \(bufferedBytes) B") }
            if let underrunCount { fields.append("waits \(underrunCount)") }
            if let installationSeconds { fields.append(String(format: "install %.3f s", installationSeconds)) }
            if let transitionSeconds { fields.append(String(format: "transition %.3f s", transitionSeconds)) }
            return fields.joined(separator: " · ")
        }
    }
    public struct Entry: Identifiable, Codable, Equatable, Sendable {
        public var id: UInt64 { sequence }
        public let sequence: UInt64
        public let timestamp: Date
        public let occurrenceID: UUID?
        public let kind: Kind
        public let phase: PlaybackWatchdog.Phase?
        public let media: MediaKind
        public let metrics: Metrics
    }
    public struct Export: Encodable, Sendable {
        public let schemaVersion = 1
        public let exportedAt: Date
        public let capacity: Int
        public let droppedEntries: Int
        public let events: [Entry]
    }

    public let capacity: Int
    public private(set) var droppedEntries = 0
    private var storage: [Entry?]
    private var nextIndex = 0
    private var count = 0
    private var sequence: UInt64 = 0
    public init(capacity: Int = 200) {
        self.capacity = min(2_000, max(1, capacity))
        storage = Array(repeating: nil, count: self.capacity)
    }
    public var entries: [Entry] {
        let start = count == capacity ? nextIndex : 0
        return (0..<count).compactMap { storage[(start + $0) % capacity] }
    }
    @discardableResult
    public mutating func append(_ kind: Kind, occurrenceID: UUID? = nil, phase: PlaybackWatchdog.Phase? = nil,
                                media: MediaKind = .unknown, metrics: Metrics = Metrics(), timestamp: Date = Date()) -> Entry {
        sequence &+= 1
        let safeDate = timestamp.timeIntervalSince1970.isFinite ? timestamp : Date(timeIntervalSince1970: 0)
        let entry = Entry(sequence: sequence, timestamp: safeDate, occurrenceID: occurrenceID, kind: kind,
                          phase: phase, media: media, metrics: metrics)
        if count == capacity { droppedEntries += 1 } else { count += 1 }
        storage[nextIndex] = entry; nextIndex = (nextIndex + 1) % capacity
        return entry
    }
    public mutating func clear() {
        storage = Array(repeating: nil, count: capacity); nextIndex = 0; count = 0; droppedEntries = 0
    }
    public func export(at date: Date = Date()) -> Export {
        Export(exportedAt: date.timeIntervalSince1970.isFinite ? date : Date(timeIntervalSince1970: 0),
               capacity: capacity, droppedEntries: droppedEntries, events: entries)
    }
}
