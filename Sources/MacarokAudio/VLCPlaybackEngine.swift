import Combine
import Foundation
import VLCKit

public enum PlaybackState: String, Sendable {
    case stopped, opening, buffering, playing, paused, failed
}

/// A single-item player. Queue order and repeat behavior belong to the application.
@MainActor
public final class VLCPlaybackEngine: NSObject, ObservableObject {
    @Published public private(set) var state: PlaybackState = .stopped
    @Published public private(set) var position: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var bufferingProgress: Double = 1
    @Published public private(set) var isSeekable = false
    @Published public private(set) var lastError: String?
    @Published public var volume: Double = 0.75 {
        didSet {
            let bounded = min(1, max(0, volume))
            if bounded != volume { volume = bounded }
            player?.audio?.volume = Int32((bounded * 100).rounded())
        }
    }

    public var onCompletion: (() -> Void)?
    public var onError: ((String) -> Void)?

    private var player: VLCMediaPlayer?
    private var proxy: PlaybackDelegate?
    private var heldStream: InputStream?
    private var generation = UUID()
    private var segmentStart: Double = 0
    private var segmentEnd: Double?
    private var durationHint: Double?
    private var hasStarted = false
    private var didComplete = false
    private var explicitlyStopped = false
    private var pendingSeek: Double?
    private var timelineTimer: Timer?
    private var live = false

    public override init() { super.init() }
    deinit { timelineTimer?.invalidate() }

    public var isPlaying: Bool { state == .playing || state == .buffering }

    public func load(
        url: URL,
        segmentStart: Double = 0,
        segmentEnd: Double? = nil,
        bufferSeconds: Double? = nil,
        durationHint: Double? = nil,
        autoplay: Bool = true,
        live: Bool = false
    ) {
        guard let media = VLCMedia(url: url) else {
            reportError("The audio resource could not be opened.")
            return
        }
        install(media: media, stream: nil, segmentStart: segmentStart, segmentEnd: segmentEnd,
                bufferSeconds: bufferSeconds, durationHint: durationHint, autoplay: autoplay, live: live)
    }

    /// The caller may supply a seekable stream backed by the shared source transport.
    /// This keeps server-specific certificate handling outside libVLC.
    public func load(
        stream: InputStream,
        segmentStart: Double = 0,
        segmentEnd: Double? = nil,
        bufferSeconds: Double? = nil,
        durationHint: Double? = nil,
        autoplay: Bool = true,
        live: Bool = false
    ) {
        guard let media = VLCMedia(stream: stream) else {
            reportError("The audio stream could not be opened.")
            return
        }
        install(media: media, stream: stream, segmentStart: segmentStart, segmentEnd: segmentEnd,
                bufferSeconds: bufferSeconds, durationHint: durationHint, autoplay: autoplay, live: live)
    }

    public func play() {
        guard let player else { return }
        explicitlyStopped = false
        if didComplete {
            didComplete = false
            position = 0
            player.time = VLCTime(number: NSNumber(value: segmentStart * 1_000))
        }
        startTimelineUpdates()
        player.play()
    }

    public func pause() { player?.pause() }

    /// A live source resumes by installing a new connection, rather than retaining old broadcast audio.
    public func pauseLive() {
        stopTimelineUpdates(); generation = UUID(); explicitlyStopped = true
        heldStream?.close(); heldStream = nil; player?.delegate = nil; player?.stop()
        pendingSeek = nil; state = .paused; position = 0; duration = 0; isSeekable = false
    }

    public func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    public func stop() {
        stopTimelineUpdates()
        explicitlyStopped = true
        pendingSeek = nil
        player?.stop()
        state = .stopped
        position = 0
        bufferingProgress = 1
    }

    public func seek(to seconds: Double) {
        guard !live, let player, seconds.isFinite else { return }
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        guard player.isSeekable else {
            pendingSeek = target
            position = target
            return
        }
        pendingSeek = nil
        player.time = VLCTime(number: NSNumber(value: (target + segmentStart) * 1_000))
        position = target
    }

    private func install(
        media: VLCMedia, stream: InputStream?, segmentStart: Double, segmentEnd: Double?,
        bufferSeconds: Double?, durationHint: Double?, autoplay: Bool, live: Bool
    ) {
        stopTimelineUpdates()
        generation = UUID()
        player?.delegate = nil
        player?.stop()
        heldStream = stream
        self.live = live
        self.segmentStart = max(0, segmentStart.isFinite ? segmentStart : 0)
        self.segmentEnd = segmentEnd.flatMap { $0.isFinite && $0 > self.segmentStart ? $0 : nil }
        self.durationHint = durationHint.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        position = 0
        duration = self.segmentEnd.map { $0 - self.segmentStart } ?? self.durationHint ?? 0
        hasStarted = false
        didComplete = false
        explicitlyStopped = false
        pendingSeek = nil
        lastError = nil
        isSeekable = false
        bufferingProgress = 0
        state = .opening

        media.addOption(":no-video")
        if self.segmentStart > 0 { media.addOption(":start-time=\(self.segmentStart)") }
        if let end = self.segmentEnd { media.addOption(":stop-time=\(end)") }
        if let seconds = bufferSeconds, seconds.isFinite, seconds > 0 {
            media.addOption(":network-caching=\(Int(min(seconds, 600) * 1_000))")
        }

        let currentPlayer = VLCMediaPlayer(options: ["--no-video", "--no-osd", "--quiet", "--no-metadata-network-access"])
        let delegate = PlaybackDelegate(owner: self, generation: generation)
        proxy = delegate
        currentPlayer.delegate = delegate
        currentPlayer.timeChangeUpdateInterval = 0.2
        currentPlayer.minimalTimePeriod = 100_000
        currentPlayer.media = media
        currentPlayer.audio?.volume = Int32((volume * 100).rounded())
        player = currentPlayer
        if autoplay { startTimelineUpdates(); currentPlayer.play() } else { state = .stopped }
    }

    private func startTimelineUpdates() {
        guard !explicitlyStopped, timelineTimer == nil else { return }
        let currentGeneration = generation
        // VLCKit's notification timer pauses while AppKit tracks an open menu.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == currentGeneration, !self.explicitlyStopped else { return }
                self.synchronizeTime()
            }
        }
        timelineTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimelineUpdates() {
        timelineTimer?.invalidate()
        timelineTimer = nil
    }

    fileprivate func receiveState(_ value: VLCMediaPlayerState, generation: UUID) {
        guard generation == self.generation else { return }
        switch value {
        case .opening:
            state = .opening
        case .playing:
            hasStarted = true
            bufferingProgress = 1
            state = .playing
            startTimelineUpdates()
            synchronizeTime()
        case .paused:
            stopTimelineUpdates()
            state = .paused
        case .stopped:
            if hasStarted && !explicitlyStopped && !didComplete { finish() }
            else if !didComplete { stopTimelineUpdates(); state = .stopped }
        case .error:
            reportError("VLC could not play this audio resource. Check the file or server connection.")
        default:
            break
        }
    }

    fileprivate func receiveTime(generation: UUID) {
        guard generation == self.generation, !explicitlyStopped else { return }
        synchronizeTime()
    }

    fileprivate func receiveBuffering(_ value: Float, generation: UUID) {
        guard generation == self.generation else { return }
        bufferingProgress = min(1, max(0, Double(value)))
        if value < 1 && state != .paused { state = .buffering }
        else if hasStarted && state == .buffering { state = .playing }
    }

    private func synchronizeTime() {
        guard let player else { return }
        let absolute = max(0, (player.time.value?.doubleValue ?? 0) / 1_000)
        let sourceDuration = max(0, (player.media?.length.value?.doubleValue ?? 0) / 1_000)
        if let end = segmentEnd { duration = end - segmentStart }
        else if sourceDuration > 0 { duration = max(0, sourceDuration - segmentStart) }
        else if let durationHint { duration = durationHint }
        isSeekable = !live && player.isSeekable
        if live { duration = 0 }
        if let target = pendingSeek {
            if isSeekable {
                pendingSeek = nil
                seek(to: target)
            }
            return
        }
        position = max(0, absolute - segmentStart)
        if duration > 0 { position = min(position, duration) }
        if hasStarted, let end = segmentEnd, absolute >= end - 0.015, !didComplete {
            finish()
        }
    }

    private func finish() {
        guard !didComplete, !explicitlyStopped else { return }
        stopTimelineUpdates()
        didComplete = true
        explicitlyStopped = true
        state = .stopped
        if duration > 0 { position = duration }
        player?.stop()
        onCompletion?()
    }

    private func reportError(_ message: String) {
        stopTimelineUpdates()
        explicitlyStopped = true
        player?.stop()
        lastError = message
        state = .failed
        onError?(message)
    }
}

private final class PlaybackDelegate: NSObject, VLCMediaPlayerDelegate {
    weak var owner: VLCPlaybackEngine?
    let generation: UUID

    init(owner: VLCPlaybackEngine, generation: UUID) {
        self.owner = owner
        self.generation = generation
    }

    func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor [weak owner, generation] in owner?.receiveState(newState, generation: generation) }
    }

    func mediaPlayerTimeChanged(_ notification: Notification) {
        Task { @MainActor [weak owner, generation] in owner?.receiveTime(generation: generation) }
    }

    func mediaPlayerBufferingChanged(_ progress: Float) {
        Task { @MainActor [weak owner, generation] in owner?.receiveBuffering(progress, generation: generation) }
    }

    func mediaPlayerLengthChanged(_ length: Int64) {
        Task { @MainActor [weak owner, generation] in owner?.receiveTime(generation: generation) }
    }
}
