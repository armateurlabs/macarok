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
                })
                .help(model.currentIsPodcast ? "Gray: not buffered · White: buffered or downloaded · Blue: played. Stream coverage is approximate for variable-bitrate audio." : "Playback position")
            Text(duration > 0 ? duration.playbackTime : "--:--").frame(width: 43, alignment: .leading)
        }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
        .onReceive(sampling) { _ in sampleBuffer() }
        .onChange(of: model.playbackGeneration) { _, _ in interaction.cancel(); sampleBuffer() }
        .onChange(of: model.currentQueueID) { _, _ in interaction.cancel(); sampleBuffer() }
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
    @Binding var value: Double
    let duration: Double
    let ranges: [Range<Double>]
    let enabled: Bool
    let showsBuffer: Bool
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> TimelineSlider {
        let slider = TimelineSlider()
        slider.cell = TimelineSliderCell()
        slider.isContinuous = true
        slider.controlSize = .mini
        slider.target = context.coordinator; slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel("Playback position")
        slider.setAccessibilityIdentifier("playbackTimeline")
        slider.onEditingChanged = { [weak coordinator = context.coordinator] editing in
            coordinator?.parent.onEditingChanged(editing)
        }
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: TimelineSlider, context: Context) {
        context.coordinator.parent = self
        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if slider.appearance?.name != appearance { slider.appearance = NSAppearance(named: appearance) }
        slider.minValue = 0; slider.maxValue = max(1, duration)
        slider.doubleValue = min(slider.maxValue, max(0, value))
        slider.isEnabled = enabled
        if let cell = slider.cell as? TimelineSliderCell { cell.bufferedRanges = ranges; cell.showsBuffer = showsBuffer }
        slider.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TimelineSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: 16)
    }
    final class Coordinator: NSObject {
        var parent: BufferedTimelineSlider
        init(parent: BufferedTimelineSlider) { self.parent = parent }
        @objc func changed(_ slider: TimelineSlider) {
            parent.value = slider.doubleValue
            if !slider.trackingMouse { parent.onEditingChanged(false) }
        }
    }
}

final class TimelineSlider: NSSlider {
    var onEditingChanged: ((Bool) -> Void)?
    private(set) var trackingMouse = false
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        trackingMouse = true; onEditingChanged?(true)
        defer { trackingMouse = false; onEditingChanged?(false) }
        super.mouseDown(with: event)
    }
}

private final class TimelineSliderCell: NSSliderCell {
    var bufferedRanges: [Range<Double>] = []
    var showsBuffer = false
    override func drawKnob(_ knobRect: NSRect) {
        super.drawKnob(knobRect)
        let dark = controlView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor(calibratedWhite: dark ? 0.78 : 0.25, alpha: isEnabled ? 0.9 : 0.45).setStroke()
        // The native tracking rectangle includes shadow/vertical padding. Its center and aspect
        // ratio need not match the visible circular thumb, which stays centered on the bar.
        let diameter = min(knobThickness, min(knobRect.width, knobRect.height))
        let bar = barRect(flipped: controlView?.isFlipped ?? false)
        let outline = NSRect(x: knobRect.midX - diameter / 2, y: bar.midY - diameter / 2,
                             width: diameter, height: diameter).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(ovalIn: outline)
        path.lineWidth = 1
        path.stroke()
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = NSRect(x: rect.minX, y: rect.midY - 1.5, width: rect.width, height: 3)
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
        let fraction = maxValue > minValue ? min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))) : 0
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: bar.width * fraction, height: bar.height), xRadius: 1.5, yRadius: 1.5).fill()
    }
}
