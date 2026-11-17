import AppKit
import Combine
import MacarokAudio
import MacarokCore
import SwiftUI

enum PlaybackTimelineMetrics {
    static let thumbDiameter: CGFloat = 16
    static let interactionHeight: CGFloat = 32
}

/// Only the compact timeline observes playback position; surrounding panels observe state changes.
struct PlaybackTimelineView: View {
    @Bindable var model: AppModel
    @ObservedObject var timeline: PlaybackTimeline
    let track: TrackRecord
    /// Set while VLC has not loaded the current entry; the timeline then edits only this start point.
    var resumePoint: Double? = nil
    @State private var interaction = PlaybackSeekInteraction()
    @State private var bufferedRanges: [Range<Double>] = []
    @State private var hover: (fraction: Double, x: CGFloat)?
    @State private var sampling = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        let duration = resumePoint != nil || timeline.duration <= 0 ? track.duration : timeline.duration
        let measured = resumePoint ?? timeline.position
        let position = interaction.isEditing ? interaction.position ?? measured : measured
        let enabled = (resumePoint != nil || timeline.isSeekable) && duration > 0
        let chapters = model.isPodcastTrack(track) ? model.podcasts.currentChapters : []
        HStack(spacing: 8) {
            if chapters.count > 1 { chapterButton(forward: false) }
            Text(position.playbackTime).frame(width: 43, alignment: .trailing)
            BufferedTimelineSlider(value: Binding(get: { min(max(1, duration), max(0, position)) }, set: {
                interaction.change(to: $0, generation: model.playbackGeneration)
            }), duration: max(1, duration), ranges: model.currentIsPodcast ? bufferedRanges : [],
                enabled: enabled,
                showsBuffer: model.currentIsPodcast,
                onEditingChanged: { editing in
                    if editing { interaction.begin(at: measured, generation: model.playbackGeneration) }
                    else if let target = interaction.end(generation: model.playbackGeneration) { model.seekPlayback(to: target) }
                }, animatesPlayback: model.player.state == .playing && model.streamingBufferFraction == nil && !interaction.isEditing,
                playbackGeneration: model.playbackGeneration, seekRevision: timeline.seekRevision,
                onEditingCancelled: { interaction.cancel() }, measuredPosition: measured,
                chapterStarts: Self.chapterFractions(chapters, duration: duration),
                onHover: { fraction, x in hover = fraction.map { ($0, x) } })
                .help(help(enabled: enabled, duration: duration))
                .overlay { if let hover, enabled || resumePoint != nil { hoverLabel(hover, chapters: chapters, duration: duration) } }
            Text(duration > 0 ? duration.playbackTime : "--:--").frame(width: 43, alignment: .leading)
            if chapters.count > 1 { chapterButton(forward: true) }
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

    static func chapterFractions(_ chapters: [PodcastChapter], duration: Double) -> [Double] {
        guard duration > 0 else { return [] }
        return chapters.map { $0.start / duration }.filter { $0 > 0 && $0 < 1 }
    }

    /// Follows the pointer above the bar: the time it points at, with that moment's chapter.
    private func hoverLabel(_ hover: (fraction: Double, x: CGFloat), chapters: [PodcastChapter], duration: Double) -> some View {
        let time = hover.fraction * duration
        let index = PodcastController.chapterIndex(chapters, at: time)
        let title = index.map { chapters[$0].title.isEmpty ? "Chapter \($0 + 1)" : chapters[$0].title }
        return GeometryReader { geometry in
            Text([time.playbackTime, title].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 10, weight: .medium)).monospacedDigit().lineLimit(1).foregroundStyle(.primary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(.separator, lineWidth: 0.5))
                .fixedSize()
                .position(x: min(max(hover.x, 70), max(70, geometry.size.width - 70)), y: -2)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func chapterButton(forward: Bool) -> some View {
        Button { model.seekChapter(forward: forward) } label: {
            Image(systemName: forward ? "arrow.right.to.line" : "arrow.left.to.line").font(.system(size: 9, weight: .semibold))
                .frame(width: 16, height: 16).contentShape(Rectangle())
        }.buttonStyle(.borderless).disabled(!model.canSeekChapters)
            .help(forward ? "Next chapter (⌥→)" : "Previous chapter (⌥←)")
            .accessibilityLabel(forward ? "Next chapter" : "Previous chapter")
    }

    private func help(enabled: Bool, duration: Double) -> String {
        if !enabled {
            if duration <= 0 { return "The duration of this track is not known yet, so it cannot be seeked." }
            if [.opening, .buffering].contains(model.player.state) { return "Seeking becomes available once the track has opened." }
            return "This server or file format does not allow seeking in this track."
        }
        if resumePoint != nil { return "Choose where playback starts." }
        return model.currentIsPodcast ? "Gray: not buffered · White: buffered or downloaded · Blue: played. Stream coverage is approximate for variable-bitrate audio." : "Playback position"
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

/// The artist, or for an episode with chapters the chapter being heard ("3/12 · Title").
struct TransportSubtitle: View {
    @Bindable var model: AppModel
    @ObservedObject var timeline: PlaybackTimeline
    let track: TrackRecord

    var body: some View {
        let chapters = model.isPodcastTrack(track) ? model.podcasts.currentChapters : []
        let position = model.seeksResumePoint ? model.restorePosition : timeline.position
        if chapters.count > 1, let index = PodcastController.chapterIndex(chapters, at: position) {
            Text("\(index + 1)/\(chapters.count) · \(chapters[index].title.isEmpty ? "Chapter \(index + 1)" : chapters[index].title)")
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(track.artist)
                .accessibilityLabel("Chapter \(index + 1) of \(chapters.count): \(chapters[index].title)")
        } else {
            Text(model.isRadioTrack(track) || track.album.isEmpty ? track.artist : "\(track.artist) — \(track.album)")
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
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
    /// Chapter boundaries as fractions of the duration, drawn as gaps in the bar.
    var chapterStarts: [Double] = []
    var onHover: ((Double?, CGFloat) -> Void)?

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
        if let cell = slider.cell as? TimelineSliderCell { cell.bufferedRanges = ranges; cell.showsBuffer = showsBuffer; cell.chapterStarts = chapterStarts }
        slider.updatePlayback(position: value, measuredPosition: measuredPosition, duration: duration, enabled: enabled,
            playing: animatesPlayback && !reduceMotion && enabled && !slider.trackingMouse,
            generation: playbackGeneration, seekRevision: seekRevision)
        slider.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TimelineSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: PlaybackTimelineMetrics.interactionHeight)
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
            slider.onHover = { [weak self] fraction, x in self?.parent.onHover?(fraction, x) }
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
    /// Pointer position over the bar as a fraction (nil when outside), with its x in view coordinates.
    var onHover: ((Double?, CGFloat) -> Void)?
    private var hoverArea: NSTrackingArea?
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area); hoverArea = area
    }

    func hoverFraction(at point: NSPoint) -> Double? {
        let bar = playbackTrackRect
        guard bar.width > 0, bounds.contains(point) else { return nil }
        return min(1, max(0, (point.x - bar.minX) / bar.width))
    }

    private func reportHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onHover?(hoverFraction(at: point), point.x)
    }

    override func mouseEntered(with event: NSEvent) { reportHover(event) }
    override func mouseMoved(with event: NSEvent) { reportHover(event) }
    override func mouseExited(with event: NSEvent) { if !trackingMouse { onHover?(nil, 0) } }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, let superview,
              bounds.contains(convert(point, from: superview)) else { return nil }
        // The whole native surface accepts clicks, including vertical breathing room around
        // the thin painted bar. Mouse mapping itself remains constrained to the track's width.
        return self
    }

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
            if next.type == .leftMouseUp {
                if !bounds.contains(point) { onHover?(nil, 0) }
                break
            }
        }
    }

    func trackMouse(at point: NSPoint) {
        guard trackingMouse, !trackingCancelled else { return }
        let bar = playbackTrackRect
        guard bar.width > 0 else { return }
        let fraction = min(1, max(0, (point.x - bar.minX) / bar.width))
        doubleValue = minValue + fraction * (maxValue - minValue)
        onHover?(fraction, min(max(point.x, bar.minX), bar.maxX))
        _ = sendAction(action, to: target)
    }
}

private final class TimelineSliderCell: NSSliderCell {
    var bufferedRanges: [Range<Double>] = []
    var showsBuffer = false
    var chapterStarts: [Double] = []
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
        let diameter = PlaybackTimelineMetrics.thumbDiameter
        return NSRect(x: bar.minX + bar.width * fraction - diameter / 2, y: bar.midY - diameter / 2,
                      width: diameter, height: diameter)
    }

    override func drawKnob(_ knobRect: NSRect) {
        let dark = controlView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // An unavailable seek must read as inactive at a glance, not as a slightly different gray.
        let gray: CGFloat = dark ? (isEnabled ? 0.78 : 0.45) : (isEnabled ? 0.25 : 0.62)
        NSColor(calibratedWhite: gray, alpha: 1).setFill()
        NSBezierPath(ovalIn: playbackThumbRect).fill()
    }

    /// Chapter boundaries cut a 2-point gap through every layer, keeping one continuous control.
    static func chapterClip(bar: NSRect, starts: [Double]) -> [NSRect] {
        var segments: [NSRect] = []
        var x = bar.minX
        for start in starts.sorted() {
            let gap = bar.minX + bar.width * start
            guard gap - 1 > x + 1, gap + 1 < bar.maxX - 1 else { continue }
            segments.append(NSRect(x: x, y: bar.minY - 1, width: gap - 1 - x, height: bar.height + 2))
            x = gap + 1
        }
        segments.append(NSRect(x: x, y: bar.minY - 1, width: bar.maxX - x, height: bar.height + 2))
        return segments
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = paintedBar(inside: rect)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if !chapterStarts.isEmpty {
            let clip = NSBezierPath()
            for segment in Self.chapterClip(bar: bar, starts: chapterStarts) { clip.appendRect(segment) }
            clip.addClip()
        }
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
