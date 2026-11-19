import AppKit
import MacarokAudio
import MacarokCore
import SwiftUI
import WebKit

/// YouTube's embedded player and search page, with the app identifying itself as the embedding site.
@MainActor
enum YouTubeWeb {
    /// YouTube refuses embedded playback without a referrer naming the embedding site (error 153).
    static let origin = URL(string: "https://com.armateurlabs.macarok/")!

    /// One persistent store, separate from Safari, keeps YouTube's consent choice and an optional sign-in.
    static let dataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6D9A7C2E-4B1F-4E8A-9C3D-2F5B8E1A7D40")!)

    static func configuration(messages: WKScriptMessageHandler? = nil) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.isElementFullscreenEnabled = true
        if let messages { configuration.userContentController.add(messages, name: "macarok") }
        return configuration
    }

    static func searchURL(_ query: String) -> URL {
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: query)]
        return components.url!
    }

    /// YouTube pages, its consent screen, and Google sign-in stay in the tab; any other link opens the browser.
    static func staysInline(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased(), url?.scheme?.lowercased() == "https" else { return false }
        return ["youtube.com", "consent.youtube.com", "accounts.google.com", "consent.google.com", "accounts.youtube.com"].contains(host)
            || host.hasSuffix(".youtube.com")
    }

    static func playerHTML(videoID: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#player{position:absolute;inset:0;width:100%;height:100%}</style>
        </head><body><div id="player"></div><script>
        function post(m){try{window.webkit.messageHandlers.macarok.postMessage(m)}catch(e){}}
        var player;
        function onYouTubeIframeAPIReady(){
          player=new YT.Player('player',{videoId:'\(videoID)',
            playerVars:{playsinline:1,rel:0,origin:'\(origin.absoluteString.dropLast())'},
            events:{onStateChange:function(e){post({event:'state',value:e.data})},onError:function(e){post({event:'error',value:e.data})}}});
        }
        function macarokPause(){if(player&&player.pauseVideo){player.pauseVideo()}}
        var tag=document.createElement('script');tag.src='https://www.youtube.com/iframe_api';document.head.appendChild(tag);
        </script></body></html>
        """
    }

    enum PlayerEvent: Equatable { case playing, stopped, refused, missing }

    /// IFrame API states and errors: https://developers.google.com/youtube/iframe_api_reference
    nonisolated static func playerEvent(_ body: Any) -> PlayerEvent? {
        guard let message = body as? [String: Any], let event = message["event"] as? String,
              let value = (message["value"] as? NSNumber)?.intValue else { return nil }
        switch (event, value) {
        case ("state", 1): return .playing
        case ("state", 0), ("state", 2): return .stopped
        case ("error", 100): return .missing
        case ("error", 101), ("error", 150), ("error", 152), ("error", 153): return .refused
        default: return nil
        }
    }
}

struct YouTubePane: View {
    @Bindable var model: AppModel
    @Bindable var links: SongLinksController
    @ObservedObject var player: VLCPlaybackEngine

    private var track: TrackRecord? { model.playingContextTrack }
    private var targetKey: [String]? { track.map { [$0.sourceID, $0.id, $0.artist, $0.title] } }

    var body: some View {
        VStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            PanelFooter {
                Text(caption).lineLimit(1)
                Spacer(minLength: 0)
                Button("Open in Browser", systemImage: "arrow.up.right.square") { if let url = browserURL { NSWorkspace.shared.open(url) } }
                    .disabled(browserURL == nil)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { follow() }
        .onChange(of: targetKey) { _, _ in follow() }
        .onChange(of: links.apiKeyRevision) { _, _ in follow(force: true) }
        .onDisappear { links.hide() }
        .accessibilityIdentifier("youtubePane")
    }

    private func follow(force: Bool = false) {
        links.show(track, kind: track.flatMap { model.sourcesByID[$0.sourceID]?.kind }, force: force)
    }

    @ViewBuilder private var content: some View {
        switch links.state {
        case .idle, .loading:
            ProgressView("Finding a video…").controlSize(.small).emptyPanel()
        case .unavailable(let message):
            ContentUnavailableView("No Video", systemImage: "play.rectangle", description: Text(message)).emptyPanel()
        case .found(let video):
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    videoArea(video)
                    VStack(alignment: .leading, spacing: 3) {
                        if !video.title.isEmpty { Text(video.title).font(.system(size: 13, weight: .semibold)).textSelection(.enabled) }
                        Text([video.channel, Self.originTitle(video.origin)].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    actions(video)
                    if video.isEmbeddable {
                        Label("Playing the video pauses your music.", systemImage: "pause.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .searching(let query, let notice):
            VStack(spacing: 0) {
                header.padding(.horizontal, 18).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text(notice ?? "No video is linked to this song. Choose one from YouTube search.")
                        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
                Divider()
                YouTubeSearchView(query: query) { links.choose(videoID: $0) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track?.title ?? "").font(.system(size: 22, weight: .semibold)).lineLimit(2)
            Text([track?.artist ?? "", track?.album ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private func videoArea(_ video: YouTubeVideo) -> some View {
        Group {
            if video.isEmbeddable {
                YouTubePlayerView(videoID: video.id, musicIsPlaying: player.state == .playing) { event in
                    switch event {
                    case .playing:
                        if [.playing, .opening, .buffering].contains(player.state) { model.pausePlayback() }
                    case .refused: links.videoRefusedEmbedding()
                    case .missing: links.searchYouTube()
                    case .stopped: break
                    }
                }
            } else {
                ZStack {
                    AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(video.id)/hqdefault.jpg")) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: { Color.black }
                    Color.black.opacity(0.6)
                    VStack(spacing: 10) {
                        Image(systemName: "play.slash").font(.system(size: 28)).foregroundStyle(.white.opacity(0.8))
                        Text("This video can only be played on YouTube.").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text("Its owner does not allow playback in other apps.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                        Button { NSWorkspace.shared.open(video.watchURL) } label: { Label("Watch on YouTube", systemImage: "arrow.up.forward.app") }
                            .buttonStyle(.borderedProminent)
                    }.multilineTextAlignment(.center).padding().environment(\.colorScheme, .dark)
                }.clipped()
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit).frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func actions(_ video: YouTubeVideo) -> some View {
        HStack(spacing: 8) {
            Button { NSWorkspace.shared.open(video.watchURL) } label: { Label("Open in YouTube", systemImage: "arrow.up.forward.app") }
            ShareButton(help: "Share this video", share: { SharePresenter.show(ShareText.video(video), from: $0) }) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            Menu("Other Videos") {
                ForEach(links.alternatives) { candidate in
                    Button(candidate.channel.isEmpty ? candidate.title : "\(candidate.title) — \(candidate.channel)") { links.choose(candidate) }
                }
                if links.alternatives.isEmpty && links.hasAPIKey {
                    Button(links.isLoadingAlternatives ? "Searching…" : "Find Other Videos") { links.loadAlternatives() }
                        .disabled(links.isLoadingAlternatives)
                }
                if !links.alternatives.isEmpty || links.hasAPIKey { Divider() }
                Button("Choose on YouTube…") { links.searchYouTube() }
            }.fixedSize()
            Spacer(minLength: 0)
        }
    }

    private var caption: String {
        switch links.state {
        case .found: "YouTube"
        case .searching: "YouTube search"
        default: "YouTube"
        }
    }

    private var browserURL: URL? {
        switch links.state {
        case .found(let video): video.watchURL
        case .searching(let query, _): YouTubeWeb.searchURL(query)
        default: nil
        }
    }

    static func originTitle(_ origin: YouTubeVideo.Origin) -> String {
        switch origin {
        case .musicBrainz: "linked by MusicBrainz"
        case .youTubeSearch: "found by YouTube search"
        case .chosen: "chosen by you"
        }
    }
}

/// The IFrame player. It reports playback and refusals, and pauses when Macarok's music starts again.
private struct YouTubePlayerView: NSViewRepresentable {
    let videoID: String
    let musicIsPlaying: Bool
    let onEvent: (YouTubeWeb.PlayerEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: YouTubeWeb.configuration(messages: WeakMessageHandler(context.coordinator)))
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onEvent = onEvent
        if coordinator.videoID != videoID {
            coordinator.videoID = videoID; coordinator.isPlaying = false
            view.loadHTMLString(YouTubeWeb.playerHTML(videoID: videoID), baseURL: YouTubeWeb.origin)
        }
        if musicIsPlaying && !coordinator.musicWasPlaying && coordinator.isPlaying {
            view.evaluateJavaScript("macarokPause()")
        }
        coordinator.musicWasPlaying = musicIsPlaying
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.evaluateJavaScript("macarokPause()")
        view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "macarok")
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var videoID: String?
        var isPlaying = false
        var musicWasPlaying = false
        var onEvent: ((YouTubeWeb.PlayerEvent) -> Void)?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let event = YouTubeWeb.playerEvent(message.body) else { return }
            isPlaying = event == .playing
            onEvent?(event)
        }

        /// The player page itself loads inline; its YouTube links (title, logo) open the browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.targetFrame?.isMainFrame == true else { return .allow }
            if action.request.url == YouTubeWeb.origin || action.request.url?.scheme == "about" { return .allow }
            if let url = action.request.url, action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            return .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}

/// YouTube's search page. Opening a video there links it to the song instead of playing it on the page.
private struct YouTubeSearchView: NSViewRepresentable {
    let query: String
    let onChoose: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: YouTubeWeb.configuration())
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        // YouTube changes pages without navigations; the address is the reliable signal.
        context.coordinator.observation = view.observe(\.url, options: [.new]) { [weak coordinator = context.coordinator] view, _ in
            MainActor.assumeIsolated { coordinator?.inspect(view.url, in: view) }
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onChoose = onChoose
        guard coordinator.query != query else { return }
        coordinator.query = query; coordinator.chosen = false
        view.load(URLRequest(url: YouTubeWeb.searchURL(query)))
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.observation = nil
        view.evaluateJavaScript("document.querySelectorAll('video').forEach(function(v){v.pause()})")
        view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var query: String?
        var chosen = false
        var onChoose: ((String) -> Void)?
        var observation: NSKeyValueObservation?

        func inspect(_ url: URL?, in view: WKWebView) {
            guard !chosen, let url, let id = YouTubeVideo.videoID(from: url) else { return }
            chosen = true
            view.stopLoading()
            view.evaluateJavaScript("document.querySelectorAll('video').forEach(function(v){v.pause()})")
            onChoose?(id)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.targetFrame?.isMainFrame == true else { return .allow }
            if let url = action.request.url, YouTubeVideo.videoID(from: url) != nil { inspect(url, in: webView); return .cancel }
            if YouTubeWeb.staysInline(action.request.url) { return .allow }
            if let url = action.request.url, action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            return .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}

/// WebKit retains script message handlers; this keeps the coordinator collectible.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
