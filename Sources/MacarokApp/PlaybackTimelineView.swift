import AppKit
import Combine
import MacarokAudio
import MacarokCore
import SwiftUI

/// Only the compact timeline observes playback position; surrounding panels observe state changes.
struct PlaybackTimelineView: View {
    @Bindable var model: AppModel
    @ObservedObject var timeline: PlaybackTimeline
    let track: TrackRecord
    @State private var interaction = PlaybackSeekInteraction()
    @State private var bufferedRanges: [Range<Double>] = []
    @State private var sampling = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        let duration = timeline.duration > 0 ? timeline.duration : track.duration
        let position = interaction.isEditing ? interaction.position ?? timeline.position : timeline.position
        HStack(spacing: 8) {
            Text(position.playbackTime).frame(width: 43, alignment: .trailing)
            BufferedTimelineSlider(value: Binding(get: { min(max(1, duration), max(0, position)) }, set: {
                interaction.change(to: $0, generation: model.playbackGeneration)
            }), duration: max(1, duration), ranges: model.currentIsPodcast ? bufferedRanges : [],
                enabled: timeline.isSeekable && duration > 0,
                showsBuffer: model.currentIsPodcast,
                onEditingChanged: { editing in
                    if editing { interaction.begin(at: timeline.position, generation: model.playbackGeneration) }
                    else if let target = interaction.end(generation: model.playbackGeneration) { model.seekPlayback(to: target) }
                }, animatesPlayback: model.player.state == .playing && model.streamingBufferFraction == nil && !interaction.isEditing,
                playbackGeneration: model.playbackGeneration, seekRevision: timeline.seekRevision,
                onEditingCancelled: { interaction.cancel() }, measuredPosition: timeline.position)
                .help(model.currentIsPodcast ? "Gray: not buffered · White: buffered or downloaded · Blue: played. Stream coverage is approximate for variable-bitrate audio." : "Playback position")
            Text(duration > 0 ? duration.playbackTime : "--:--").frame(width: 43, alignment: .leading)
        }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
        .onReceive(sampling) { _ in sampleBuffer() }
        .onChange(of: model.playbackGeneration) { _, _ in interaction.cancel(); sampleBuffer() }
        .onChange(of: model.currentQueueID) { _, _ in interaction.cancel(); sampleBuffer() }
        .onChange(of: timeline.seekRevision) { _, _ in interaction.cancel() }
        .onChange(of: model.player.state) { _, state in
            if [.opening, .stopped, .failed].contains(state) { interaction.cancel() }
        }
        .onAppear { sampleBuffer() }
    }

    private func sampleBuffer() {
        var next: [Range<Double>]
        if model.podcastDownloads?.localURL(for: track) != nil { next = [0..<1] }
        else if let snapshot = model.activeStream?.snapshot { next = Self.normalizedRanges(snapshot) }
        else { next = [] }
        if let fraction = model.podcastDownloads?.progress[PodcastDownloadsController.key(track)]?.fraction, fraction > 0 {
            next.append(0..<fraction)
        }
        next = Self.merged(next)
        if next != bufferedRanges { bufferedRanges = next }
    }

    static func normalizedRanges(_ snapshot: StreamBufferSnapshot) -> [Range<Double>] {
        guard let total = snapshot.totalBytes, total > 0 else { return [] }
        return snapshot.retainedRanges.compactMap { range in
            let lower = min(1, max(0, Double(range.lowerBound) / Double(total)))
            let upper = min(1, max(lower, Double(range.upperBound) / Double(total)))
            return upper > lower ? lower..<upper : nil
        }
    }

    static func merged(_ ranges: [Range<Double>]) -> [Range<Double>] {
        var result: [Range<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { result.append(range) }
        }
        return result
    }
}

/// Native tracking, keyboard navigation, and accessibility with a custom layered progress bar.
struct BufferedTimelineSlider: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var value: Double
    let duration: Double
    let ranges: [Range<Double>]
    let enabled: Bool
    let showsBuffer: Bool
    let onEditingChanged: (Bool) -> Void
    var animatesPlayback = false
    var playbackGeneration: UUID?
    var seekRevision: UInt64 = 0
    var onEditingCancelled: (() -> Void)?
    var measuredPosition: Double?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> TimelineSlider {
        let slider = Self.makeSlider()
        context.coordinator.connect(slider)
        return slider
    }
    static func makeSlider() -> TimelineSlider {
        let slider = TimelineSlider()
        slider.cell = TimelineSliderCell()
        slider.isContinuous = true
        slider.controlSize = .mini
        slider.setAccessibilityLabel("Playback position")
        slider.setAccessibilityIdentifier("playbackTimeline")
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: TimelineSlider, context: Context) {
        context.coordinator.parent = self
        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if slider.appearance?.name != appearance { slider.appearance = NSAppearance(named: appearance) }
        if let cell = slider.cell as? TimelineSliderCell { cell.bufferedRanges = ranges; cell.showsBuffer = showsBuffer }
        slider.updatePlayback(position: value, measuredPosition: measuredPosition, duration: duration, enabled: enabled,
            playing: animatesPlayback && !reduceMotion && enabled && !slider.trackingMouse,
            generation: playbackGeneration, seekRevision: seekRevision)
        slider.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TimelineSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: 16)
    }
    static func dismantleNSView(_ slider: TimelineSlider, coordinator: Coordinator) { slider.stopPresentationUpdates() }
    final class Coordinator: NSObject {
        var parent: BufferedTimelineSlider
        init(parent: BufferedTimelineSlider) { self.parent = parent }
        func connect(_ slider: TimelineSlider) {
            slider.target = self; slider.action = #selector(changed(_:))
            slider.onEditingChanged = { [weak self] editing in self?.parent.onEditingChanged(editing) }
            slider.onFinalTrackingValue = { [weak self] value in self?.parent.value = value }
            slider.onTrackingCancelled = { [weak self] in self?.parent.onEditingCancelled?() }
        }
        @objc func changed(_ slider: TimelineSlider) {
            guard slider.acceptNativeInput() else { return }
            parent.value = slider.doubleValue
            if !slider.trackingMouse { parent.onEditingChanged(false) }
        }
    }
}

final class TimelineSlider: NSSlider {
    var onEditingChanged: ((Bool) -> Void)?
    var onFinalTrackingValue: ((Double) -> Void)?
    var onTrackingCancelled: (() -> Void)?
    private(set) var trackingMouse = false
    private(set) var trackingCancelled = false
    private var trackingStartValue: Double = 0
    private var trackingValueChanged = false
    private var trackingGeneration: UUID?
    private var trackingSeekRevision: UInt64 = 0
    private var smoothing = PlaybackTimelineSmoothing()
    private var presentationTimer: Timer?
    private var presentationGeneration: UUID?
    private var presentationSeekRevision: UInt64 = 0
    private var latestMeasuredPosition: Double = 0

    var renderedPosition: Double { (cell as? TimelineSliderCell)?.renderedValue ?? doubleValue }
    var playbackTrackRect: NSRect { (cell as? TimelineSliderCell)?.playbackTrackRect ?? bounds }
    var playbackThumbRect: NSRect { (cell as? TimelineSliderCell)?.playbackThumbRect ?? .zero }

    deinit { presentationTimer?.invalidate() }

    func updatePlayback(position: Double, measuredPosition: Double? = nil, duration: Double, enabled: Bool,
                        playing: Bool, generation: UUID?, seekRevision: UInt64,
                        at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        latestMeasuredPosition = measuredPosition ?? position
        // Native tracking owns its value and range until release. SwiftUI can deliver a queued
        // binding/clock value from earlier in the gesture while AppKit's nested event loop runs.
        guard !defersPlaybackUpdate(generation: generation, seekRevision: seekRevision, enabled: enabled) else {
            needsDisplay = true
            return
        }
        minValue = 0; maxValue = max(1, duration); isEnabled = enabled
        applyPlaybackPosition(min(maxValue, max(0, position)), playing: playing, generation: generation,
                              seekRevision: seekRevision, measuredPosition: measuredPosition, at: time)
    }

    func applyPlaybackPosition(_ position: Double, playing: Bool, generation: UUID?, seekRevision: UInt64,
                               measuredPosition: Double? = nil,
                               at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        latestMeasuredPosition = measuredPosition ?? position
        guard !defersPlaybackUpdate(generation: generation, seekRevision: seekRevision, enabled: isEnabled) else { return }
        // Native input and accessibility retain the measured value. Only this cell's painting
        // follows a short interpolation, without publishing 60 Hz changes through the view model.
        let target = trackingMouse && trackingCancelled ? latestMeasuredPosition : position
        doubleValue = min(maxValue, max(minValue, target))
        presentationGeneration = generation; presentationSeekRevision = seekRevision
        let value = smoothing.update(to: doubleValue, at: time, playing: playing,
                                     generation: generation, seekRevision: seekRevision)
        (cell as? TimelineSliderCell)?.presentationValue = value
        if smoothing.isAnimating(at: time) { startPresentationUpdates() }
        else { stopPresentationUpdates() }
        needsDisplay = true
    }

    func advancePresentation(to time: TimeInterval) {
        (cell as? TimelineSliderCell)?.presentationValue = smoothing.value(at: time)
        needsDisplay = true
        if !smoothing.isAnimating(at: time) { stopPresentationUpdates() }
    }

    private func startPresentationUpdates() {
        guard presentationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advancePresentation(to: ProcessInfo.processInfo.systemUptime) }
        }
        presentationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopPresentationUpdates() { presentationTimer?.invalidate(); presentationTimer = nil }

    func synchronizeInputPresentation() {
        let value = smoothing.update(to: doubleValue, at: ProcessInfo.processInfo.systemUptime, playing: false,
                                     generation: presentationGeneration, seekRevision: presentationSeekRevision)
        stopPresentationUpdates()
        (cell as? TimelineSliderCell)?.presentationValue = value
        needsDisplay = true
    }

    func defersPlaybackUpdate(generation: UUID?, seekRevision: UInt64, enabled: Bool) -> Bool {
        guard trackingMouse else { return false }
        if generation != trackingGeneration || seekRevision != trackingSeekRevision || !enabled {
            trackingCancelled = true
            stopPresentationUpdates()
        }
        return !trackingCancelled
    }

    func acceptNativeInput() -> Bool {
        if trackingMouse {
            guard !trackingCancelled else { return false }
            if doubleValue != trackingStartValue { trackingValueChanged = true }
            guard trackingValueChanged else { return false }
        }
        synchronizeInputPresentation()
        return true
    }

    @discardableResult
    func beginTrackingGesture() -> Bool {
        guard isEnabled, !trackingMouse else { return false }
        synchronizeInputPresentation()
        trackingMouse = true; trackingCancelled = false; trackingValueChanged = false
        trackingStartValue = doubleValue
        trackingGeneration = presentationGeneration; trackingSeekRevision = presentationSeekRevision
        onEditingChanged?(true)
        return true
    }

    func finishTrackingGesture() {
        guard trackingMouse else { return }
        if trackingCancelled {
            doubleValue = min(maxValue, max(minValue, latestMeasuredPosition))
            synchronizeInputPresentation()
            onTrackingCancelled?()
        } else if trackingValueChanged || doubleValue != trackingStartValue {
            synchronizeInputPresentation()
            // Capture the final native value even if AppKit's last action preceded mouse-up.
            onFinalTrackingValue?(doubleValue)
        } else {
            doubleValue = min(maxValue, max(minValue, latestMeasuredPosition))
            synchronizeInputPresentation()
        }
        trackingMouse = false
        onEditingChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = convert(event.locationInWindow, from: nil)
        let startsOnThumb = playbackThumbRect.insetBy(dx: -4, dy: -4).contains(start)
        guard beginTrackingGesture() else { return }
        defer { finishTrackingGesture() }
        window.makeFirstResponder(self)
        let wasVisible = window.isVisible, wasKey = window.isKeyWindow
        var moved = !startsOnThumb
        if moved { trackMouse(at: start) }
        // NSSliderCell's private drag/page policy can apply an offset when its hit rectangle
        // differs from a custom-painted thumb. Use the exact painted track for every mouse
        // position, retaining NSSlider's keyboard, focus, accessibility, and action semantics.
        while true {
            guard self.window === window, (!wasVisible || window.isVisible), (!wasKey || window.isKeyWindow) else {
                trackingCancelled = true
                break
            }
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                until: Date(timeIntervalSinceNow: 0.25), inMode: .eventTracking, dequeue: true) else {
                if !wasVisible { break } // A hidden window has no further live mouse input to wait for.
                continue
            }
            let point = convert(next.locationInWindow, from: nil)
            if abs(point.x - start.x) > 0.25 { moved = true }
            if moved { trackMouse(at: point) }
            if next.type == .leftMouseUp { break }
        }
    }

    func trackMouse(at point: NSPoint) {
        guard trackingMouse, !trackingCancelled else { return }
        let bar = playbackTrackRect
        guard bar.width > 0 else { return }
        let fraction = min(1, max(0, (point.x - bar.minX) / bar.width))
        doubleValue = minValue + fraction * (maxValue - minValue)
        _ = sendAction(action, to: target)
    }
}

private final class TimelineSliderCell: NSSliderCell {
    var bufferedRanges: [Range<Double>] = []
    var showsBuffer = false
    var presentationValue: Double?

    var renderedValue: Double {
        if let slider = controlView as? TimelineSlider, slider.trackingMouse, !slider.trackingCancelled { return doubleValue }
        return presentationValue ?? doubleValue
    }

    private var fraction: Double {
        maxValue > minValue ? min(1, max(0, (renderedValue - minValue) / (maxValue - minValue))) : 0
    }

    private func paintedBar(inside rect: NSRect) -> NSRect {
        // Match native knob travel: the center has half a tracking-knob's width of end padding.
        let padding = min(knobThickness / 2, rect.width / 2)
        return NSRect(x: rect.minX + padding, y: rect.midY - 1.5,
                      width: max(0, rect.width - padding * 2), height: 3)
    }

    var playbackTrackRect: NSRect { paintedBar(inside: barRect(flipped: controlView?.isFlipped ?? false)) }
    var playbackThumbRect: NSRect {
        let bar = playbackTrackRect
        return NSRect(x: bar.minX + bar.width * fraction - 4, y: bar.midY - 4, width: 8, height: 8)
    }

    override func drawKnob(_ knobRect: NSRect) {
        let dark = controlView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let gray: CGFloat = dark ? (isEnabled ? 0.78 : 0.58) : (isEnabled ? 0.25 : 0.45)
        NSColor(calibratedWhite: gray, alpha: 1).setFill()
        NSBezierPath(ovalIn: playbackThumbRect).fill()
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = paintedBar(inside: rect)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        if showsBuffer {
            for range in bufferedRanges {
                let segment = NSRect(x: bar.minX + bar.width * range.lowerBound, y: bar.minY,
                                     width: bar.width * (range.upperBound - range.lowerBound), height: bar.height)
                NSColor.white.setFill(); segment.fill()
                NSColor.separatorColor.setStroke(); let border = NSBezierPath(rect: segment); border.lineWidth = 0.5; border.stroke()
            }
        }
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: bar.width * fraction, height: bar.height), xRadius: 1.5, yRadius: 1.5).fill()
    }
}
