import AppKit
import MacarokCore
import Observation
import SwiftUI

/// YouTube and Wikipedia links of the song in the YouTube tab and in shared text.
/// Lookups run only while the tab is visible or when sharing; the API key is read from Keychain on first need.
@MainActor @Observable
final class SongLinksController {
    enum VideoState: Equatable {
        case idle
        case unavailable(String)
        case loading
        case found(YouTubeVideo)
        /// No linked video: YouTube's own search page, where choosing a video links it to the song.
        case searching(query: String, notice: String?)
    }

    private(set) var key: SongKey?
    private(set) var state: VideoState = .idle
    private(set) var alternatives: [YouTubeVideo] = []
    private(set) var isLoadingAlternatives = false

    var apiKeyInput = ""
    private(set) var hasAPIKey = false
    private(set) var hasLoadedAPIKey = false
    private(set) var settingsNotice: String?
    /// Changes when the key is saved, so a visible YouTube tab searches again.
    private(set) var apiKeyRevision = 0

    @ObservationIgnored let resolver: SongLinkResolver
    @ObservationIgnored private let keychain: YouTubeKeychainStore
    @ObservationIgnored private var apiKey: String?
    @ObservationIgnored private var lookup: Task<Void, Never>?

    init(store: LibraryStore, client: SongLinkClient = SongLinkClient(), keychain: YouTubeKeychainStore = YouTubeKeychainStore()) {
        resolver = SongLinkResolver(store: store, client: client)
        self.keychain = keychain
    }

    // MARK: YouTube tab

    func show(_ track: TrackRecord?, kind: SourceKind?, force: Bool = false) {
        guard let track else { cancel(); state = .unavailable("Play or select a song to find its video."); key = nil; return }
        if kind == .radio || kind?.isPodcast == true {
            cancel(); key = nil
            state = .unavailable(kind == .radio ? "Radio stations have no song video." : "Podcast episodes have no song video.")
            return
        }
        guard let key = SongKey(track: track) else {
            cancel(); self.key = nil; state = .unavailable("This track needs an artist and a title to find its video."); return
        }
        guard force || key != self.key || state == .idle else { return }
        cancel()
        self.key = key; alternatives = []; state = .loading
        lookup = Task { [weak self] in
            guard let self else { return }
            let apiKey = await self.loadAPIKey()
            do {
                let result = try await resolver.video(for: key, apiKey: apiKey)
                guard !Task.isCancelled, self.key == key else { return }
                alternatives = result.alternatives
                state = result.video.map(VideoState.found) ?? .searching(query: Self.query(key), notice: nil)
            } catch {
                guard !Task.isCancelled, self.key == key else { return }
                // A failed search still leaves YouTube's own search page.
                state = .searching(query: Self.query(key), notice: (error as? LocalizedError)?.errorDescription)
            }
        }
    }

    func hide() { cancel(); key = nil; state = .idle; alternatives = [] }

    private func cancel() { lookup?.cancel(); lookup = nil }

    static func query(_ key: SongKey) -> String { "\(key.artist) \(key.title)" }

    var currentVideo: YouTubeVideo? { if case .found(let video) = state { video } else { nil } }

    /// A video picked on YouTube's search page becomes this song's video.
    func choose(videoID: String) {
        guard let key else { return }
        state = .loading
        Task {
            let video = (try? await resolver.choose(videoID: videoID, for: key)) ?? YouTubeVideo(id: videoID, title: "", channel: "", origin: .chosen)
            guard self.key == key else { return }
            alternatives.removeAll { $0.id == videoID }
            state = .found(video)
        }
    }

    func choose(_ video: YouTubeVideo) {
        guard let key else { return }
        var chosen = video; chosen.origin = .chosen
        if let current = currentVideo, !alternatives.contains(where: { $0.id == current.id }) { alternatives.insert(current, at: 0) }
        alternatives.removeAll { $0.id == video.id }
        state = .found(chosen)
        Task { try? await resolver.choose(chosen, for: key) }
    }

    func searchYouTube() {
        guard let key else { return }
        cancel(); state = .searching(query: Self.query(key), notice: nil)
    }

    func loadAlternatives() {
        guard let key, !isLoadingAlternatives, alternatives.isEmpty else { return }
        isLoadingAlternatives = true
        Task {
            defer { isLoadingAlternatives = false }
            guard let apiKey = await loadAPIKey(), let found = try? await resolver.alternatives(for: key, apiKey: apiKey, excluding: currentVideo?.id),
                  self.key == key else { return }
            alternatives = found
        }
    }

    /// The embedded player refused the video: keep its details and offer YouTube instead.
    func videoRefusedEmbedding() {
        guard let key, var video = currentVideo, video.isEmbeddable else { return }
        let original = video
        video.isEmbeddable = false
        state = .found(video)
        Task { try? await resolver.markNotEmbeddable(original, for: key) }
    }

    // MARK: API key

    func loadAPIKey() async -> String? {
        if hasLoadedAPIKey { return apiKey }
        let keychain = keychain
        let stored = try? await Task.detached { try keychain.load() }.value
        apiKey = stored.flatMap { $0.isEmpty ? nil : $0 }
        hasAPIKey = apiKey != nil; hasLoadedAPIKey = true
        if apiKeyInput.isEmpty { apiKeyInput = apiKey ?? "" }
        return apiKey
    }

    func saveAPIKey() async {
        let value = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let keychain = keychain
        do {
            if value.isEmpty { try await Task.detached { try keychain.delete() }.value }
            else { try await Task.detached { try keychain.save(value) }.value }
            apiKey = value.isEmpty ? nil : value
            hasAPIKey = apiKey != nil; hasLoadedAPIKey = true
            settingsNotice = value.isEmpty ? "The YouTube API key was removed." : "The YouTube API key was saved in Keychain."
            apiKeyRevision += 1
        } catch {
            settingsNotice = "Keychain could not save the key."
        }
    }

    // MARK: Sharing

    /// Known links come first; a missing link is looked up for at most a few seconds, then left out.
    func shareLinks(for key: SongKey) async -> [URL] {
        async let wikipedia = Self.withTimeout(4) { [resolver] in try? await resolver.wikipedia(for: key) }
        let video: URL?
        if let cached = await resolver.cachedVideo(for: key) { video = cached.watchURL }
        else {
            let apiKey = await loadAPIKey()
            video = await Self.withTimeout(4) { [resolver] in try? await resolver.video(for: key, apiKey: apiKey).video?.watchURL }
        }
        return [await wikipedia, video].compactMap { $0 }
    }

    nonisolated static func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Shows the native macOS share menu below a view, or at the pointer when the request comes from a context menu.
@MainActor
enum SharePresenter {
    static func show(_ text: String, from view: NSView?) {
        guard !text.isEmpty else { return }
        let picker = NSSharingServicePicker(items: [text])
        if let view, view.window != nil {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else if let window = NSApp.keyWindow ?? NSApp.mainWindow, let content = window.contentView {
            let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            picker.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: content, preferredEdge: .minY)
        }
    }
}

/// Exposes the AppKit view behind a SwiftUI control so the share menu can point at it.
final class ShareAnchor {
    weak var view: NSView?
}

private struct ShareAnchorView: NSViewRepresentable {
    let anchor: ShareAnchor
    func makeNSView(context: Context) -> NSView { let view = NSView(); anchor.view = view; return view }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

struct ShareButton<Label: View>: View {
    let help: String
    let share: (NSView?) -> Void
    @ViewBuilder let label: () -> Label
    @State private var anchor = ShareAnchor()

    var body: some View {
        Button(action: { share(anchor.view) }, label: label)
            .background(ShareAnchorView(anchor: anchor))
            .help(help)
            .accessibilityLabel(help)
    }
}
