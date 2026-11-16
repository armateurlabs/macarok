import Combine
import Foundation
import os
import VLCKit

public enum PlaybackState: String, Sendable {
    case stopped, opening, buffering, playing, paused, failed
}

/// High-frequency clock values are observed only by views that draw the timeline or synchronized lyrics.
@MainActor
public final class PlaybackTimeline: ObservableObject {
    @Published public fileprivate(set) var position: Double = 0
    @Published public fileprivate(set) var duration: Double = 0
    @Published public fileprivate(set) var bufferingProgress: Double = 1
    @Published public fileprivate(set) var isSeekable = false
    @Published public fileprivate(set) var seekRevision: UInt64 = 0
}

public struct PlaybackDiagnostics: Equatable, Sendable {
    public fileprivate(set) var installationCount = 0
    public fileprivate(set) var lastInstallationSeconds: TimeInterval = 0
    public fileprivate(set) var lastTransitionSeconds: TimeInterval?
}

public struct PlaybackHealthSnapshot: Equatable, Sendable {
    public let position: Double
    public let playedAudioBuffers: UInt64?
    public let decodedAudio: UInt64?
    public let readBytes: UInt64?
}

public struct PlaybackHandoffTiming: Equatable, Sendable {
    public let requestedAt: Date
    public let requestedUptime: TimeInterval
    public let firstPlayingAt: Date?
    public let firstPlayingUptime: TimeInterval?
}

/// Queue order and repeat behavior belong to the application. One prepared successor can start
/// from VLC's native completion callback while the main actor is busy publishing library work.
@MainActor
public final class VLCPlaybackEngine: NSObject, ObservableObject {
    @Published public private(set) var state: PlaybackState = .stopped
    public let timeline = PlaybackTimeline()
    public private(set) var diagnostics = PlaybackDiagnostics()
    public private(set) var position: Double {
        get { timeline.position }
        set { if timeline.position != newValue { timeline.position = newValue } }
    }
    public private(set) var duration: Double {
        get { timeline.duration }
        set { if timeline.duration != newValue { timeline.duration = newValue } }
    }
    public private(set) var bufferingProgress: Double {
        get { timeline.bufferingProgress }
        set { if timeline.bufferingProgress != newValue { timeline.bufferingProgress = newValue } }
    }
    public private(set) var isSeekable: Bool {
        get { timeline.isSeekable }
        set { if timeline.isSeekable != newValue { timeline.isSeekable = newValue } }
    }
    @Published public private(set) var lastError: String?
    public var volume: Double = 0.75 {
        didSet {
            guard volume != oldValue else { return }
            let bounded = min(1, max(0, volume))
            if bounded != volume { volume = bounded }
            handoff.setVolume(Int32((bounded * 100).rounded()))
            player?.audio?.volume = Int32((bounded * 100).rounded())
        }
    }

    public var onCompletion: (() -> Void)?
    public var onError: ((String) -> Void)?
    public var onHandoff: ((UUID) -> Void)?
    /// When the successor was submitted to VLC, rather than when the main actor adopted it.
    public private(set) var lastHandoffStartedAt: Date?
    public var handoffTiming: PlaybackHandoffTiming? {
        guard let current = handoff.current(), let date = current.startedAt, let uptime = current.startedUptime else { return nil }
        return PlaybackHandoffTiming(requestedAt: date, requestedUptime: uptime,
                                     firstPlayingAt: current.firstPlayingAt, firstPlayingUptime: current.firstPlayingUptime)
    }

    public var healthSnapshot: PlaybackHealthSnapshot {
        synchronizeUpcomingPlayback()
        guard let current = handoff.current(), current.hasStarted else {
            return PlaybackHealthSnapshot(position: position, playedAudioBuffers: nil, decodedAudio: nil, readBytes: nil)
        }
        let statistics = current.backend.media.statistics
        return PlaybackHealthSnapshot(position: position, playedAudioBuffers: statistics.playedAudioBuffers,
                                      decodedAudio: statistics.decodedAudio, readBytes: statistics.readBytes)
    }

    private var player: VLCMediaPlayer?
    private var proxy: PlaybackDelegate?
    private var heldStream: InputStream?
    private var streamSupportsSeeking: (@Sendable () -> Bool?)?
    private var generation = UUID()
    private var segmentStart: Double = 0
    private var segmentEnd: Double?
    private var durationHint: Double?
    private var hasStarted = false
    private var didComplete = false
    private var explicitlyStopped = false
    private var pendingSeek: Double?
    private var playingSince: TimeInterval?
    private var inFlightSeek: (target: Double, startedAt: TimeInterval)?
    private var timelineTimer: Timer?
    private var live = false
    private nonisolated let handoff = NativePlaybackHandoff()
    private static let eventConfiguration: PlaybackEventsConfiguration = {
        let configuration = PlaybackEventsConfiguration()
        VLCLibrary.sharedEventsConfiguration = configuration
        return configuration
    }()
    private static let playbackLibrary: VLCLibrary = {
        _ = eventConfiguration
        return VLCLibrary(options: ["--no-video", "--no-osd", "--quiet", "--no-metadata-network-access"])
    }()
    private static let signposter = OSSignposter(subsystem: "com.armateurlabs.Macarok", category: "Playback")
    private var transitionInterval: OSSignpostIntervalState?
    private var transitionStartedAt: TimeInterval?

    // Exposed internally for regressions without leaking VLCKit through the public application API.
    var libraryIdentity: ObjectIdentifier? { player.map { ObjectIdentifier($0.libraryInstance) } }
    nonisolated var nativePlaybackToken: UUID? { handoff.current()?.backend.token }
    nonisolated var nativePlayedAudioBuffers: UInt64? {
        guard let current = handoff.current(), current.hasStarted else { return nil }
        return current.backend.media.statistics.playedAudioBuffers
    }

    public override init() {
        // Install once before load() can create even its VLCMedia/shared library. The framework's
        // default inline callbacks can release a notification's last player reference while
        // libVLC still holds its timer lock; dealloc then re-enters that lock to unwatch time.
        _ = VLCPlaybackEngine.eventConfiguration
        super.init()
    }
    deinit {
        timelineTimer?.invalidate()
        handoff.stopAll()
    }

    public var isPlaying: Bool { state == .playing || state == .buffering }

    private func setState(_ next: PlaybackState) {
        guard state != next else { return }
        state = next
    }

    private func endTransition(startedPlaying: Bool = false, at uptime: TimeInterval? = nil) {
        if startedPlaying, let started = transitionStartedAt {
            diagnostics.lastTransitionSeconds = max(0, (uptime ?? ProcessInfo.processInfo.systemUptime) - started)
        }
        transitionStartedAt = nil
        if let interval = transitionInterval { Self.signposter.endInterval("TrackTransition", interval) }
        transitionInterval = nil
    }

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
                bufferSeconds: bufferSeconds, durationHint: durationHint, autoplay: autoplay, live: live,
                localFile: url.isFileURL, supportsSeeking: nil)
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
        live: Bool = false,
        supportsSeeking: (@Sendable () -> Bool?)? = nil
    ) {
        guard let media = VLCMedia(stream: stream) else {
            reportError("The audio stream could not be opened.")
            return
        }
        install(media: media, stream: stream, segmentStart: segmentStart, segmentEnd: segmentEnd,
                bufferSeconds: bufferSeconds, durationHint: durationHint, autoplay: autoplay, live: live,
                localFile: false, supportsSeeking: supportsSeeking)
    }

    @discardableResult
    public func setUpcoming(
        token: UUID, url: URL, segmentStart: Double = 0, segmentEnd: Double? = nil,
        bufferSeconds: Double? = nil, durationHint: Double? = nil, live: Bool = false
    ) -> Bool {
        synchronizeUpcomingPlayback()
        guard let media = VLCMedia(url: url) else { return false }
        let backend = makeBackend(media: media, token: token, stream: nil, segmentStart: segmentStart,
                                  segmentEnd: segmentEnd, bufferSeconds: bufferSeconds, durationHint: durationHint,
                                  live: live, localFile: url.isFileURL, supportsSeeking: nil)
        return handoff.setUpcoming(backend)
    }

    @discardableResult
    public func setUpcoming(
        token: UUID, stream: InputStream, segmentStart: Double = 0, segmentEnd: Double? = nil,
        bufferSeconds: Double? = nil, durationHint: Double? = nil, live: Bool = false,
        supportsSeeking: (@Sendable () -> Bool?)? = nil
    ) -> Bool {
        synchronizeUpcomingPlayback()
        guard let media = VLCMedia(stream: stream) else { return false }
        let backend = makeBackend(media: media, token: token, stream: stream, segmentStart: segmentStart,
                                  segmentEnd: segmentEnd, bufferSeconds: bufferSeconds, durationHint: durationHint,
                                  live: live, localFile: false, supportsSeeking: supportsSeeking)
        return handoff.setUpcoming(backend)
    }

    /// A ready native handoff is adopted before cancelling the still-queued successor. The callback
    /// may therefore run synchronously; callers must cancel here before releasing prepared streams.
    public func cancelUpcoming() {
        synchronizeUpcomingPlayback()
        handoff.cancelUpcoming()
    }

    /// Returns false without changing current playback when this token is no longer prepared.
    /// On success, onHandoff has run synchronously before this method returns.
    @discardableResult
    public func playUpcoming(token: UUID) -> Bool {
        let previousGeneration = generation
        synchronizeUpcomingPlayback()
        if previousGeneration != generation, handoff.current()?.backend.token == token { return true }
        guard handoff.promote(token: token) else { return false }
        synchronizeUpcomingPlayback()
        return true
    }

    /// Publishes a handoff already started by VLC. Queue edits call this before taking a snapshot
    /// so their idea of the current entry matches the decoder even after a busy main run loop.
    public func synchronizeUpcomingPlayback() {
        guard let current = handoff.current(), current.backend.generation != generation,
              let token = current.backend.token else { return }
        adopt(current)
        onHandoff?(token)
    }

    public func play() {
        synchronizeUpcomingPlayback()
        guard let player else { return }
        if handoff.current() == nil, let proxy, let media = player.media {
            player.delegate = proxy
            handoff.install(PlaybackBackend(generation: generation, token: nil, player: player, media: media,
                                            delegate: proxy, stream: heldStream, supportsSeeking: streamSupportsSeeking,
                                            segmentStart: segmentStart, segmentEnd: segmentEnd,
                                            durationHint: durationHint, live: live))
        }
        explicitlyStopped = false
        if didComplete {
            didComplete = false
            position = 0
            player.time = VLCTime(number: NSNumber(value: segmentStart * 1_000))
        }
        startTimelineUpdates()
        player.play()
    }

    public func pause() { synchronizeUpcomingPlayback(); player?.pause() }

    /// A live source resumes by installing a new connection, rather than retaining old broadcast audio.
    public func pauseLive() {
        endTransition()
        stopTimelineUpdates(); generation = UUID(); explicitlyStopped = true
        handoff.stopAll()
        heldStream?.close(); heldStream = nil; player?.delegate = nil; player?.stop()
        pendingSeek = nil; inFlightSeek = nil; setState(.paused); position = 0; duration = 0; isSeekable = false
    }

    public func togglePlayPause() {
        synchronizeUpcomingPlayback()
        if isPlaying { pause() } else { play() }
    }

    public func stop() {
        endTransition()
        stopTimelineUpdates()
        explicitlyStopped = true
        pendingSeek = nil
        inFlightSeek = nil
        handoff.stopAll()
        player?.stop()
        setState(.stopped)
        position = 0
        bufferingProgress = 1
        isSeekable = false
    }

    public func seek(to seconds: Double) {
        synchronizeUpcomingPlayback()
        guard !live, let player, seconds.isFinite else { return }
        guard streamSupportsSeeking?() != false else {
            pendingSeek = nil; inFlightSeek = nil; isSeekable = false
            return
        }
        let target = boundedSeekTarget(seconds)
        timeline.seekRevision &+= 1
        guard player.isSeekable else {
            pendingSeek = target
            inFlightSeek = nil
            position = target
            return
        }
        pendingSeek = nil
        inFlightSeek = (target, ProcessInfo.processInfo.systemUptime)
        player.time = VLCTime(number: NSNumber(value: (target + segmentStart) * 1_000))
        position = target
    }

    /// A stalled decoder is a recoverable playback error, never a successful queue completion.
    public func failStalledPlayback(_ message: String) {
        synchronizeUpcomingPlayback()
        guard !explicitlyStopped else { return }
        reportError(message)
    }

    private func boundedSeekTarget(_ seconds: Double) -> Double {
        // RSS durations are provisional. In particular, a saved resume point can arrive before
        // VLC opens the episode, so only a CUE boundary or decoded duration may truncate it.
        let limit: Double?
        if let end = segmentEnd { limit = end - segmentStart }
        else if let milliseconds = player?.media?.length.value?.doubleValue,
                milliseconds.isFinite, milliseconds > 0 { limit = max(0, milliseconds / 1_000 - segmentStart) }
        else { limit = nil }
        return max(0, limit.map { min(seconds, $0) } ?? seconds)
    }

    private func install(
        media: VLCMedia, stream: InputStream?, segmentStart: Double, segmentEnd: Double?,
        bufferSeconds: Double?, durationHint: Double?, autoplay: Bool, live: Bool, localFile: Bool,
        supportsSeeking: (@Sendable () -> Bool?)?
    ) {
        let installationStarted = ProcessInfo.processInfo.systemUptime
        let installationInterval = Self.signposter.beginInterval("Install", id: Self.signposter.makeSignpostID())
        defer {
            diagnostics.installationCount += 1
            diagnostics.lastInstallationSeconds = ProcessInfo.processInfo.systemUptime - installationStarted
            Self.signposter.endInterval("Install", installationInterval)
        }
        endTransition()
        if autoplay {
            diagnostics.lastTransitionSeconds = nil
            transitionStartedAt = installationStarted
            transitionInterval = Self.signposter.beginInterval("TrackTransition", id: Self.signposter.makeSignpostID())
        }
        stopTimelineUpdates()
        handoff.stopAll()
        player?.delegate = nil
        player?.stop()
        let backend = makeBackend(media: media, token: nil, stream: stream, segmentStart: segmentStart,
                                  segmentEnd: segmentEnd, bufferSeconds: bufferSeconds, durationHint: durationHint,
                                  live: live, localFile: localFile, supportsSeeking: supportsSeeking)
        handoff.install(backend)
        adopt(NativePlaybackSnapshot(backend: backend, hasStarted: false, startedAt: nil, startedUptime: nil),
              preserveTransition: true)
        lastHandoffStartedAt = nil
        if autoplay { startTimelineUpdates(); backend.player.play() } else { setState(.stopped) }
    }

    private func makeBackend(
        media: VLCMedia, token: UUID?, stream: InputStream?, segmentStart: Double, segmentEnd: Double?,
        bufferSeconds: Double?, durationHint: Double?, live: Bool, localFile: Bool,
        supportsSeeking: (@Sendable () -> Bool?)?
    ) -> PlaybackBackend {
        let start = max(0, segmentStart.isFinite ? segmentStart : 0)
        let end = segmentEnd.flatMap { $0.isFinite && $0 > start ? $0 : nil }
        let hint = durationHint.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        media.addOption(":no-video")
        if start > 0 { media.addOption(":start-time=\(start)") }
        if let end { media.addOption(":stop-time=\(end)") }
        if let seconds = bufferSeconds, seconds.isFinite, seconds > 0 {
            media.addOption(":network-caching=\(Int(min(seconds, 600) * 1_000))")
        }
        if localFile {
            // Mounted SMB/NAS resources are still file URLs. Give their decoder a bounded cache.
            let seconds = bufferSeconds.flatMap { $0.isFinite && $0 > 0 ? min($0, 600) : nil } ?? 1
            media.addOption(":file-caching=\(Int(seconds * 1_000))")
        }
        let generation = UUID()
        let currentPlayer = VLCMediaPlayer(library: Self.playbackLibrary)
        let delegate = PlaybackDelegate(owner: self, generation: generation, handoff: handoff)
        currentPlayer.delegate = delegate
        currentPlayer.timeChangeUpdateInterval = 0.2
        currentPlayer.minimalTimePeriod = 100_000
        currentPlayer.media = media
        currentPlayer.audio?.volume = Int32((volume * 100).rounded())
        return PlaybackBackend(generation: generation, token: token, player: currentPlayer, media: media,
                               delegate: delegate, stream: stream, supportsSeeking: supportsSeeking,
                               segmentStart: start, segmentEnd: end, durationHint: hint, live: live)
    }

    private func adopt(_ snapshot: NativePlaybackSnapshot, preserveTransition: Bool = false) {
        let backend = snapshot.backend
        stopTimelineUpdates()
        if !preserveTransition {
            endTransition()
            transitionStartedAt = snapshot.startedUptime
            transitionInterval = Self.signposter.beginInterval("TrackTransition", id: Self.signposter.makeSignpostID())
            diagnostics.lastTransitionSeconds = nil
        }
        generation = backend.generation
        player = backend.player
        proxy = backend.delegate
        heldStream = backend.stream
        streamSupportsSeeking = backend.supportsSeeking
        live = backend.live
        segmentStart = backend.segmentStart
        segmentEnd = backend.segmentEnd
        durationHint = backend.durationHint
        position = 0
        duration = segmentEnd.map { $0 - segmentStart } ?? durationHint ?? 0
        hasStarted = snapshot.hasStarted
        playingSince = hasStarted ? snapshot.firstPlayingUptime ?? ProcessInfo.processInfo.systemUptime : nil
        didComplete = false
        explicitlyStopped = false
        pendingSeek = nil
        inFlightSeek = nil
        if lastError != nil { lastError = nil }
        isSeekable = false
        bufferingProgress = hasStarted ? 1 : 0
        lastHandoffStartedAt = snapshot.startedAt
        setState(.opening)
        if !preserveTransition { startTimelineUpdates() }
        if hasStarted {
            endTransition(startedPlaying: true, at: snapshot.firstPlayingUptime)
            setState(.playing)
        }
    }

    private func startTimelineUpdates() {
        guard !explicitlyStopped, timelineTimer == nil else { return }
        let currentGeneration = generation
        // VLCKit's notification timer pauses while AppKit tracks an open menu.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.synchronizeUpcomingPlayback()
                guard self.generation == currentGeneration, !self.explicitlyStopped else { return }
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
        synchronizeUpcomingPlayback()
        guard generation == self.generation else { return }
        guard !explicitlyStopped else { return }
        switch value {
        case .opening:
            setState(.opening)
        case .playing:
            endTransition(startedPlaying: true, at: handoff.current()?.firstPlayingUptime)
            hasStarted = true
            if playingSince == nil { playingSince = ProcessInfo.processInfo.systemUptime }
            bufferingProgress = 1
            setState(.playing)
            startTimelineUpdates()
            synchronizeTime()
        case .paused:
            stopTimelineUpdates()
            setState(.paused)
        case .stopped:
            if hasStarted && !explicitlyStopped && !didComplete { finish() }
            else if !didComplete { stopTimelineUpdates(); setState(.stopped) }
        case .error:
            reportError("VLC could not play this audio resource. Check the file or server connection.")
        default:
            break
        }
    }

    fileprivate func receiveTime(generation: UUID) {
        synchronizeUpcomingPlayback()
        guard generation == self.generation, !explicitlyStopped else { return }
        // The common-mode clock already samples playing media at 5 Hz. Delegate notifications
        // are still needed for paused seeks, initial duration discovery, and seek acknowledgement.
        if state != .playing || pendingSeek != nil || inFlightSeek != nil || duration == 0 { synchronizeTime() }
    }

    fileprivate func receiveBuffering(_ value: Float, generation: UUID) {
        synchronizeUpcomingPlayback()
        guard generation == self.generation, !explicitlyStopped else { return }
        bufferingProgress = min(1, max(0, Double(value)))
        if value < 1 && state != .paused { setState(.buffering) }
        else if hasStarted && state == .buffering { setState(.playing) }
    }

    private func synchronizeTime() {
        synchronizeUpcomingPlayback()
        guard !explicitlyStopped else { return }
        guard let player else { return }
        let absolute = max(0, (player.time.value?.doubleValue ?? 0) / 1_000)
        let sourceDuration = max(0, (player.media?.length.value?.doubleValue ?? 0) / 1_000)
        if let end = segmentEnd { duration = end - segmentStart }
        else if sourceDuration > 0 { duration = max(0, sourceDuration - segmentStart) }
        else if let durationHint { duration = durationHint }
        let transportAllowsSeeking = streamSupportsSeeking?() != false
        isSeekable = !live && transportAllowsSeeking && player.isSeekable
        if !transportAllowsSeeking { pendingSeek = nil; inFlightSeek = nil }
        if live { duration = 0 }
        if let target = pendingSeek {
            if isSeekable {
                pendingSeek = nil
                seek(to: target)
                return
            }
            // Media that is still unseekable after playback began never applies the target.
            // Report the audio actually heard instead of holding the timeline on it.
            guard hasStarted, let playingSince, ProcessInfo.processInfo.systemUptime - playingSince >= 2 else { return }
            pendingSeek = nil
        }
        let reportedPosition = max(0, absolute - segmentStart)
        if let request = inFlightSeek {
            let elapsed = ProcessInfo.processInfo.systemUptime - request.startedAt
            let target = boundedSeekTarget(request.target)
            let acknowledged = reportedPosition >= target - 0.5 && reportedPosition <= target + max(1, elapsed + 0.5)
            if !acknowledged, elapsed < 15 {
                // VLCKit can report its cached pre-seek time while the new byte range is buffering.
                // Do not move the cursor back or evaluate a CUE end boundary from that old sample.
                position = target
                return
            }
            inFlightSeek = nil
        }
        position = reportedPosition
        if duration > 0 { position = min(position, duration) }
        if hasStarted, let end = segmentEnd, absolute >= end - 0.015, !didComplete {
            finish()
        }
    }

    private func finish() {
        guard !didComplete, !explicitlyStopped else { return }
        // The explicit CUE boundary can be sampled just before VLC's native stop callback.
        if handoff.promoteAfterCompletion(generation: generation) {
            synchronizeUpcomingPlayback()
            return
        }
        endTransition()
        stopTimelineUpdates()
        didComplete = true
        explicitlyStopped = true
        inFlightSeek = nil
        setState(.stopped)
        if duration > 0 { position = duration }
        handoff.stopAll()
        player?.stop()
        onCompletion?()
    }

    private func reportError(_ message: String) {
        endTransition()
        stopTimelineUpdates()
        explicitlyStopped = true
        pendingSeek = nil; inFlightSeek = nil; isSeekable = false
        handoff.stopAll()
        player?.stop()
        if lastError != message { lastError = message }
        setState(.failed)
        onError?(message)
    }
}

/// Immutable ownership for an installed or prepared decoder. Mutable handoff state is protected
/// by NativePlaybackHandoff's lock; VLCKit's documented player controls remain native operations.
private final class PlaybackBackend: @unchecked Sendable {
    let generation: UUID
    let token: UUID?
    let player: VLCMediaPlayer
    let media: VLCMedia
    let delegate: PlaybackDelegate
    let stream: InputStream?
    let supportsSeeking: (@Sendable () -> Bool?)?
    let segmentStart: Double
    let segmentEnd: Double?
    let durationHint: Double?
    let live: Bool

    init(generation: UUID, token: UUID?, player: VLCMediaPlayer, media: VLCMedia, delegate: PlaybackDelegate,
         stream: InputStream?, supportsSeeking: (@Sendable () -> Bool?)?, segmentStart: Double,
         segmentEnd: Double?, durationHint: Double?, live: Bool) {
        self.generation = generation; self.token = token; self.player = player; self.media = media
        self.delegate = delegate; self.stream = stream; self.supportsSeeking = supportsSeeking
        self.segmentStart = segmentStart; self.segmentEnd = segmentEnd; self.durationHint = durationHint; self.live = live
    }

    func retire() {
        player.delegate = nil
        player.stop()
        stream?.close()
    }
}

private struct NativePlaybackSnapshot: Sendable {
    let backend: PlaybackBackend
    var hasStarted: Bool
    let startedAt: Date?
    let startedUptime: TimeInterval?
    var firstPlayingAt: Date?
    var firstPlayingUptime: TimeInterval?
}

/// Keep VLCKit's notification creation and autorelease pools outside libVLC's locked callbacks.
/// The public process-wide configuration is owned by MacarokAudio and retained for its lifetime.
/// A serial queue preserves event order and remains independent of a busy main actor.
private final class PlaybackEventsConfiguration: NSObject, VLCEventsConfiguring {
    private let queue = DispatchQueue(label: "com.armateurlabs.Macarok.playback-events", qos: .userInitiated,
                                      autoreleaseFrequency: .workItem)

    func dispatchQueue() -> DispatchQueue? { queue }
    func isAsync() -> Bool { true }
}

/// State changes arrive on the dedicated playback event queue; public play() enqueues decoder
/// work. This bridge avoids undocumented native handles and does not promise gapless transitions.
private final class NativePlaybackHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var active: NativePlaybackSnapshot?
    private var upcoming: PlaybackBackend?

    func current() -> NativePlaybackSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    func install(_ backend: PlaybackBackend) {
        lock.lock()
        active = NativePlaybackSnapshot(backend: backend, hasStarted: false, startedAt: nil, startedUptime: nil)
        lock.unlock()
    }

    func setUpcoming(_ backend: PlaybackBackend) -> Bool {
        lock.lock()
        guard active != nil else { lock.unlock(); backend.retire(); return false }
        let previous = upcoming
        upcoming = backend
        lock.unlock()
        previous?.retire()
        return true
    }

    func cancelUpcoming() {
        lock.lock()
        let previous = upcoming
        upcoming = nil
        lock.unlock()
        previous?.retire()
    }

    func stopAll() {
        lock.lock()
        let previous = active?.backend, prepared = upcoming
        active = nil; upcoming = nil
        lock.unlock()
        previous?.retire()
        prepared?.retire()
    }

    func setVolume(_ value: Int32) {
        lock.lock()
        let players = [active?.backend.player, upcoming?.player].compactMap { $0 }
        lock.unlock()
        for player in players { player.audio?.volume = value }
    }

    func received(_ state: VLCMediaPlayerState, generation: UUID) {
        switch state {
        case .playing:
            lock.lock()
            if active?.backend.generation == generation {
                active?.hasStarted = true
                if active?.firstPlayingAt == nil {
                    active?.firstPlayingAt = Date()
                    active?.firstPlayingUptime = ProcessInfo.processInfo.systemUptime
                }
            }
            lock.unlock()
        case .stopped:
            _ = promoteAfterCompletion(generation: generation)
        default:
            break
        }
    }

    @discardableResult
    func promoteAfterCompletion(generation: UUID) -> Bool {
        promote(token: nil, completing: generation)
    }

    @discardableResult
    func promote(token: UUID) -> Bool { promote(token: token, completing: nil) }

    private func promote(token: UUID?, completing generation: UUID?) -> Bool {
        lock.lock()
        guard let current = active, let next = upcoming,
              token.map({ next.token == $0 }) ?? true else { lock.unlock(); return false }
        if let generation {
            guard current.backend.generation == generation, current.hasStarted, !current.backend.live else {
                lock.unlock(); return false
            }
        }
        upcoming = nil
        active = NativePlaybackSnapshot(backend: next, hasStarted: false, startedAt: Date(),
                                        startedUptime: ProcessInfo.processInfo.systemUptime)
        lock.unlock()

        current.backend.player.stop()
        lock.lock()
        // A simultaneous Stop may have invalidated this promotion before play was enqueued.
        // Keep this tiny enqueue inside the lock so Stop always follows an accepted play request.
        if active?.backend.generation == next.generation { next.player.play() }
        lock.unlock()
        current.backend.stream?.close()
        return true
    }
}

private final class PlaybackDelegate: NSObject, VLCMediaPlayerDelegate {
    weak var owner: VLCPlaybackEngine?
    let generation: UUID
    private weak var handoff: NativePlaybackHandoff?

    init(owner: VLCPlaybackEngine, generation: UUID, handoff: NativePlaybackHandoff) {
        self.owner = owner
        self.generation = generation
        self.handoff = handoff
    }

    func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        handoff?.received(newState, generation: generation)
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
