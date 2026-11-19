import AppKit
import Foundation
import MacarokAudio
import MacarokCore
import Observation
import os
import SwiftUI
import UniformTypeIdentifiers

/// Low-frequency health observations and a bounded event history, shared by playback and Help.
@MainActor @Observable
final class PlaybackDiagnosticsController {
    /// How VLC receives the current media; FLAC/Ogg byte streams cannot be seeked by libVLC.
    enum Transport: String, Codable {
        case file, directNetwork, bufferedStream, none
        var title: String {
            switch self {
            case .file: "File"
            case .directNetwork: "VLC network access"
            case .bufferedStream: "Macarok buffered stream"
            case .none: "—"
            }
        }
    }
    struct Snapshot: Codable, Equatable {
        let phase: PlaybackWatchdog.Phase
        let media: PlaybackEventLog.MediaKind
        let hasProgressSignal: Bool
        let isSuspended: Bool
        let metrics: PlaybackEventLog.Metrics
        var isSeekable: Bool? = nil
        var transport: Transport? = nil
    }
    private struct Export: Encodable {
        let schemaVersion = 1
        let snapshot: Snapshot?
        let log: PlaybackEventLog.Export
    }
    private(set) var snapshot: Snapshot?
    private(set) var events: [PlaybackEventLog.Entry] = []
    private(set) var droppedEntries = 0
    var exportFailed = false
    @ObservationIgnored private var watchdog: PlaybackWatchdog
    @ObservationIgnored private var log: PlaybackEventLog
    @ObservationIgnored private var occurrenceID: UUID?
    @ObservationIgnored private var lastPhase: PlaybackWatchdog.Phase?
    @ObservationIgnored private var lastUnderruns = 0
    @ObservationIgnored private var lastInstallationCount = 0
    @ObservationIgnored private var reportedMissingSignal = false
    @ObservationIgnored private var windowController: NSWindowController?
    private static let logger = Logger(subsystem: "com.armateurlabs.Macarok", category: "Playback diagnostics")

    init(configuration: PlaybackWatchdog.Configuration = .init(), capacity: Int = 200) {
        watchdog = PlaybackWatchdog(configuration: configuration)
        log = PlaybackEventLog(capacity: capacity)
    }

    /// The caller samples on the playback clock and owns the single explicit recovery action.
    @discardableResult
    func observe(_ sample: PlaybackWatchdog.Sample, engine: PlaybackDiagnostics,
                 stream: StreamBufferSnapshot?, media: PlaybackEventLog.MediaKind = .unknown,
                 health: PlaybackHealthSnapshot? = nil, duration: Double? = nil,
                 isSeekable: Bool? = nil, transport: Transport? = nil) -> PlaybackWatchdog.Incident? {
        let metrics = PlaybackEventLog.Metrics(position: sample.position, duration: duration,
            playedAudioBuffers: health?.playedAudioBuffers ?? sample.audioOutputCounter,
            decodedAudio: health?.decodedAudio, readBytes: health?.readBytes ?? sample.transportProgressCounter,
            bufferedBytes: stream?.bufferedBytes, bufferCapacityBytes: stream?.capacityBytes,
            underrunCount: stream?.underrunCount, readerWaitSeconds: stream?.readerWaitDuration,
            installationCount: engine.installationCount, installationSeconds: engine.lastInstallationSeconds,
            transitionSeconds: engine.lastTransitionSeconds)
        let next = Snapshot(phase: sample.phase, media: media, hasProgressSignal: sample.hasProgressSignal,
                            isSuspended: sample.isSuspended, metrics: metrics, isSeekable: isSeekable, transport: transport)
        if snapshot != next { snapshot = next }
        if occurrenceID != sample.occurrenceID {
            occurrenceID = sample.occurrenceID; lastPhase = nil; lastUnderruns = 0; reportedMissingSignal = false
            if sample.occurrenceID != nil { record(.occurrenceStarted, occurrenceID: sample.occurrenceID, phase: sample.phase, media: media, metrics: metrics) }
        }
        if lastPhase != sample.phase {
            if lastPhase != nil || sample.occurrenceID != nil {
                record(sample.phase == .failed ? .failed : .phaseChanged, occurrenceID: sample.occurrenceID, phase: sample.phase, media: media, metrics: metrics)
            }
            lastPhase = sample.phase
        }
        if engine.installationCount > lastInstallationCount {
            record(.installation, occurrenceID: sample.occurrenceID, phase: sample.phase, media: media, metrics: metrics)
        }
        lastInstallationCount = engine.installationCount
        if let waits = stream?.underrunCount {
            if waits > lastUnderruns { record(.underrun, occurrenceID: sample.occurrenceID, phase: sample.phase, media: media, metrics: metrics) }
            lastUnderruns = waits
        }
        if sample.phase == .playing, !sample.hasProgressSignal, !reportedMissingSignal {
            reportedMissingSignal = true
            record(.monitoringUnavailable, occurrenceID: sample.occurrenceID, phase: sample.phase, media: media)
        }
        guard let incident = watchdog.sample(sample) else { return nil }
        record(.watchdog, occurrenceID: incident.occurrenceID, phase: sample.phase, media: media,
               metrics: .init(position: sample.position, bufferedBytes: stream?.bufferedBytes,
                   underrunCount: stream?.underrunCount, secondsWithoutProgress: incident.secondsWithoutProgress,
                   reason: incident.reason, transportIsAdvancing: incident.transportIsAdvancing))
        return incident
    }

    func markSeek(occurrenceID: UUID, monotonicTime: TimeInterval) {
        watchdog.markSeek(occurrenceID: occurrenceID, monotonicTime: monotonicTime)
        record(.seek, occurrenceID: occurrenceID, phase: snapshot?.phase, media: snapshot?.media ?? .unknown)
    }
    func record(_ kind: PlaybackEventLog.Kind, occurrenceID: UUID? = nil,
                phase: PlaybackWatchdog.Phase? = nil, media: PlaybackEventLog.MediaKind = .unknown,
                metrics: PlaybackEventLog.Metrics = .init(), failure: Error? = nil) {
        let entry = log.append(kind, occurrenceID: occurrenceID, phase: phase, media: media, metrics: metrics)
        events = log.entries; droppedEntries = log.droppedEntries
        // Every interpolated string is from a closed enum, numeric metrics, or an error's type, never caller error text.
        if kind == .failed || kind == .watchdog {
            Self.logger.error("\(entry.kind.rawValue, privacy: .public) phase=\(phase?.rawValue ?? "none", privacy: .public) media=\(media.rawValue, privacy: .public) \(metrics.summary, privacy: .public)\(failure.map { " error=" + Self.errorType($0) } ?? "", privacy: .public)")
        } else if kind.isWarning {
            Self.logger.warning("\(entry.kind.rawValue, privacy: .public) phase=\(phase?.rawValue ?? "none", privacy: .public) \(metrics.summary, privacy: .public)")
        } else {
            Self.logger.info("\(entry.kind.rawValue, privacy: .public) phase=\(phase?.rawValue ?? "none", privacy: .public) \(metrics.summary, privacy: .public)")
        }
    }
    func clearEvents() { log.clear(); events = []; droppedEntries = 0 }

    /// Domain and code identify a failure without its message, which can contain names or addresses.
    static func errorType(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.domain)#\(value.code)"
    }
    func exportData(at date: Date = Date()) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Export(snapshot: snapshot, log: log.export(at: date)))
    }
    func copyDiagnostics() {
        do {
            let data = try exportData()
            guard let text = String(data: data, encoding: .utf8) else { exportFailed = true; return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        } catch { exportFailed = true }
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Macarok-playback-diagnostics.json"
        panel.title = "Export Playback Diagnostics"; panel.prompt = "Export"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try self?.exportData().write(to: url, options: .atomic) }
            catch { self?.exportFailed = true }
        }
    }
    func showWindow(appearance: ColorScheme? = nil) {
        if windowController == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: PlaybackDiagnosticsView(controller: self)))
            window.title = "Playback Diagnostics"; window.setContentSize(NSSize(width: 820, height: 600))
            window.minSize = NSSize(width: 680, height: 460)
            window.styleMask.insert([.resizable, .miniaturizable]); window.isReleasedWhenClosed = false
            window.center(); windowController = NSWindowController(window: window)
        }
        windowController?.window?.appearance = appearance.flatMap { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) }
        windowController?.showWindow(nil); windowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct PlaybackDiagnosticsView: View {
    @Bindable var controller: PlaybackDiagnosticsController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playback Diagnostics").font(.title2.bold())
            Text("Session-only counters and events. Track titles, source names, addresses, credentials, and file paths are excluded.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let snapshot = controller.snapshot {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow { field("State", snapshot.phase.title); field("Media", snapshot.media.title) }
                    GridRow { field("Transport", snapshot.transport?.title ?? "—"); field("Seekable", snapshot.isSeekable.map { $0 ? "Yes" : "No" } ?? "—") }
                    GridRow { field("Position", seconds(snapshot.metrics.position)); field("Duration", seconds(snapshot.metrics.duration)) }
                    GridRow { field("Played audio buffers", number(snapshot.metrics.playedAudioBuffers)); field("Decoded audio", number(snapshot.metrics.decodedAudio)) }
                    GridRow { field("VLC bytes read", number(snapshot.metrics.readBytes)); field("Stream buffer", buffer(snapshot.metrics)) }
                    GridRow { field("Reader waits", snapshot.metrics.underrunCount.map(String.init) ?? "—"); field("Reader wait time", seconds(snapshot.metrics.readerWaitSeconds)) }
                    GridRow { field("Player installations", snapshot.metrics.installationCount.map(String.init) ?? "—"); field("Last installation", seconds(snapshot.metrics.installationSeconds)) }
                    GridRow { field("Last transition", seconds(snapshot.metrics.transitionSeconds)); field("Progress monitor", snapshot.isSuspended ? "Suspended" : snapshot.hasProgressSignal ? "Available" : "Unavailable") }
                }
                .font(.callout).textSelection(.enabled)
            } else { Text("Playback has not been sampled in this session.").foregroundStyle(.secondary) }
            Divider()
            HStack {
                Text("Recent Events").font(.headline)
                Spacer()
                Text("\(controller.events.count) retained · \(controller.droppedEntries) older discarded").font(.caption).foregroundStyle(.secondary)
            }
            Table(controller.events.reversed()) {
                TableColumn("Time") { event in Text(event.timestamp, format: .dateTime.hour().minute().second()).monospacedDigit() }.width(75)
                TableColumn("Event") { event in Text(event.kind.title) }.width(min: 140, ideal: 170)
                TableColumn("State") { event in Text(event.phase?.title ?? "—") }.width(75)
                TableColumn("Details") { event in Text(event.metrics.summary).foregroundStyle(.secondary).lineLimit(2) }
            }
            .frame(minHeight: 130)
            HStack {
                Button("Clear Event Log", action: controller.clearEvents).disabled(controller.events.isEmpty)
                Spacer()
                Button("Copy Diagnostics", action: controller.copyDiagnostics)
                Button("Export…", action: controller.exportDiagnostics)
            }
        }
        .padding(20).frame(minWidth: 640, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Could Not Export Diagnostics", isPresented: $controller.exportFailed) { Button("OK", role: .cancel) { } }
            message: { Text("Choose another destination and try again.") }
    }
    private func field(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) { Text(label).foregroundStyle(.secondary); Spacer(minLength: 6); Text(value).monospacedDigit() }
    }
    private func seconds(_ value: Double?) -> String { value.map { String(format: "%.3f s", $0) } ?? "—" }
    private func number(_ value: UInt64?) -> String { value.map(String.init) ?? "—" }
    private func buffer(_ value: PlaybackEventLog.Metrics) -> String {
        guard let bytes = value.bufferedBytes, let capacity = value.bufferCapacityBytes else { return "—" }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)) / \(ByteCountFormatter.string(fromByteCount: Int64(capacity), countStyle: .memory))"
    }
}
