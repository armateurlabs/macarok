import AppKit
import Foundation
import MacarokCore
import Observation

struct EpisodeDownloadProgress: Equatable {
    let received: Int64
    let expected: Int64?
    var fraction: Double? { expected.flatMap { $0 > 0 ? min(1, Double(received) / Double($0)) : nil } }
}

private final class DownloadProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -Double.infinity
    func accepts(received: Int64, expected: Int64?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - last >= 0.2 || expected == received else { return false }
        last = now; return true
    }
}

@MainActor private final class WeakDownloadController {
    weak var value: PodcastDownloadsController?
    init(_ value: PodcastDownloadsController) { self.value = value }
}

@MainActor @Observable
final class PodcastDownloadsController {
    let directory: URL
    private(set) var downloads: [String: PodcastDownload] = [:]
    private(set) var progress: [String: EpisodeDownloadProgress] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var isLoading = false
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let storage: PodcastDownloadStore
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var requests: [String: UUID] = [:]
    @ObservationIgnored private var taskSources: [String: String] = [:]

    init(model: AppModel, directory: URL) {
        self.model = model; self.directory = directory
        storage = PodcastDownloadStore(directory: directory)
    }

    func start() async {
        isLoading = true; defer { isLoading = false }
        do { downloads = Dictionary(uniqueKeysWithValues: try await storage.list().map { ($0.id, $0) }) }
        catch { model?.fail("Could not read podcast downloads", error.localizedDescription) }
    }

    static func key(_ track: TrackRecord) -> String { PodcastDownloadStore.key(sourceID: track.sourceID, trackID: track.id) }
    func localURL(for track: TrackRecord) -> URL? {
        downloads[Self.key(track)].map { directory.appendingPathComponent($0.filename) }
    }
    func isDownloading(_ track: TrackRecord) -> Bool { progress[Self.key(track)] != nil }

    func download(_ track: TrackRecord) {
        let key = Self.key(track)
        guard tasks[key] == nil, downloads[key] == nil,
              let model, let source = model.sources.first(where: { $0.id == track.sourceID }), source.kind == .podcasts else { return }
        let id = UUID(); requests[key] = id; taskSources[key] = source.id
        errors[key] = nil; progress[key] = EpisodeDownloadProgress(received: 0, expected: nil)
        let transport = model.transport(for: source), gate = DownloadProgressGate(), storage = storage
        let receiver = WeakDownloadController(self)
        tasks[key] = Task { [weak self] in
            do {
                let record = try await storage.download(track: track, transport: transport) { received, expected in
                    guard gate.accepts(received: received, expected: expected) else { return }
                    Task { @MainActor in
                        guard let self = receiver.value, self.requests[key] == id else { return }
                        let next = EpisodeDownloadProgress(received: received, expected: expected)
                        if self.progress[key] != next { self.progress[key] = next }
                    }
                }
                guard let self, self.requests[key] == id else { return }
                self.downloads[key] = record
            } catch is CancellationError { }
            catch {
                guard let self, self.requests[key] == id else { return }
                if !Task.isCancelled {
                    self.errors[key] = error.localizedDescription
                    self.model?.fail("Episode download failed", error.localizedDescription)
                }
            }
            guard let self, self.requests[key] == id else { return }
            self.progress[key] = nil; self.tasks[key] = nil; self.requests[key] = nil; self.taskSources[key] = nil
        }
    }

    func cancel(_ track: TrackRecord) { cancel(key: Self.key(track)) }
    private func cancel(key: String) {
        tasks[key]?.cancel()
    }
    func cancel(sourceIDs: Set<String>) {
        for key in Array(taskSources.keys) where taskSources[key].map(sourceIDs.contains) == true { cancel(key: key) }
    }
    func cancelAll() { for key in Array(tasks.keys) { cancel(key: key) } }

    func reveal(_ download: PodcastDownload) {
        Task {
            if let url = await storage.file(for: download) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { downloads[download.id] = nil; model?.status = "The downloaded episode is no longer on disk. Download it again to keep a local copy." }
        }
    }
    func openFolder() {
        Task {
            do { _ = try await storage.list(); NSWorkspace.shared.open(directory) }
            catch { model?.fail("Could not open downloads", error.localizedDescription) }
        }
    }
    func remove(_ download: PodcastDownload) {
        guard canRemove(download) else { return }
        Task {
            do { try await storage.remove(id: download.id); downloads[download.id] = nil }
            catch { model?.fail("Could not remove download", error.localizedDescription) }
        }
    }
    func canRemove(_ download: PodcastDownload) -> Bool {
        guard let model, let current = model.currentTrack,
              current.id == download.trackID && current.sourceID == download.sourceID else { return true }
        return [.stopped, .failed].contains(model.player.state)
    }
}
