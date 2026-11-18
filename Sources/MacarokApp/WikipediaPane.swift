import AppKit
import MacarokCore
import Observation
import SwiftUI
import WebKit

enum WikipediaTopic: String, CaseIterable, Identifiable {
    case artist, album
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum WikipediaLookup {
    static func query(for track: TrackRecord?, topic: WikipediaTopic) -> String? {
        guard let track else { return nil }
        let artist = meaningful(track.artist, placeholder: "Unknown Artist")
        let albumArtist = meaningful(track.albumArtist, placeholder: "Unknown Artist")
        switch topic {
        case .artist: return artist ?? albumArtist
        case .album:
            guard let album = meaningful(track.album, placeholder: "Unknown Album") else { return nil }
            return [album, albumArtist ?? artist, "album"].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// MediaWiki's Go search opens an exact article when possible and otherwise returns search results.
    /// https://www.mediawiki.org/wiki/Help:Go_button
    static func searchURL(for query: String) -> URL? {
        let query = cleaned(query)
        guard !query.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"; components.host = "en.wikipedia.org"; components.path = "/w/index.php"
        components.queryItems = [URLQueryItem(name: "title", value: "Special:Search"), URLQueryItem(name: "search", value: query),
                                 URLQueryItem(name: "go", value: "Go"), URLQueryItem(name: "ns0", value: "1"),
                                 URLQueryItem(name: "useskin", value: "minerva")]
        return components.url
    }

    static func cleaned(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private static func meaningful(_ value: String, placeholder: String) -> String? {
        let value = cleaned(value)
        return value.isEmpty || value.caseInsensitiveCompare(placeholder) == .orderedSame ? nil : value
    }

    enum Navigation: Equatable { case inline, external, cancel }
    static func navigation(for url: URL?, userInitiated: Bool) -> Navigation {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return .cancel }
        if ["en.wikipedia.org", "en.m.wikipedia.org"].contains(url.host!.lowercased()),
           url.port == nil || url.port == (url.scheme?.lowercased() == "https" ? 443 : 80) { return .inline }
        return userInitiated ? .external : .cancel
    }
}

/// Request generations are independent of WebKit, so stale callbacks and visibility cancellation are testable offline.
@MainActor @Observable
final class WikipediaBrowserSession {
    enum State: Equatable { case idle, loading, loaded, failed(String) }
    private(set) var state: State = .idle
    private(set) var generation = UUID()
    private(set) var isVisible = false
    private(set) var requestedURL: URL?
    private(set) var displayURL: URL?
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var cancellation: (() -> Void)?

    func bind(owner: UUID, cancellation: @escaping () -> Void) { self.owner = owner; self.cancellation = cancellation }
    func unbind(owner: UUID) { if self.owner == owner { self.owner = nil; cancellation = nil } }
    func show(_ url: URL, force: Bool = false) {
        if isVisible && requestedURL == url && !force {
            if state == .loading || state == .loaded { return }
        }
        cancellation?(); generation = UUID(); isVisible = true
        requestedURL = url; displayURL = url; state = .loading
    }
    func hide() {
        cancellation?(); generation = UUID(); isVisible = false
        requestedURL = nil; displayURL = nil; state = .idle
    }
    func started(generation: UUID, url: URL?) {
        guard isVisible, self.generation == generation else { return }
        state = .loading
        if let url { displayURL = url }
    }
    func finished(generation: UUID, url: URL?) {
        guard isVisible, self.generation == generation else { return }
        state = .loaded
        if let url { displayURL = url }
    }
    func failed(generation: UUID, message: String) {
        guard isVisible, self.generation == generation else { return }
        state = .failed(message)
    }
}

struct WikipediaPane: View {
    @Bindable var model: AppModel
    @State private var topic: WikipediaTopic = .artist
    @State private var search = ""
    @State private var browser = WikipediaBrowserSession()
    private var targetKey: [String]? {
        model.playingContextTrack.map { [$0.sourceID, $0.id, $0.artist, $0.albumArtist, $0.album] }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader {
                Picker("Wikipedia topic", selection: $topic) {
                    ForEach(WikipediaTopic.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 208).frame(maxWidth: .infinity)
            }
            HStack(spacing: 8) {
                TextField("Search Wikipedia", text: $search).textFieldStyle(.roundedBorder).onSubmit { submit() }
                    .accessibilityIdentifier("wikipediaSearch")
                Button("Search", action: submit).disabled(WikipediaLookup.cleaned(search).isEmpty)
            }.controlSize(.small).padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            PanelFooter {
                Text("Wikipedia · English")
                Spacer(minLength: 0)
                Button("Open in Browser", systemImage: "arrow.up.right.square") {
                    if let url = browser.displayURL { NSWorkspace.shared.open(url) }
                }.disabled(browser.displayURL == nil)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { followTarget() }
        .onChange(of: targetKey) { _, _ in followTarget() }
        .onChange(of: topic) { _, _ in followTarget() }
        .onDisappear { browser.hide() }
        .accessibilityIdentifier("wikipediaPane")
    }

    @ViewBuilder private var content: some View {
        if browser.requestedURL != nil {
            ZStack {
                WikipediaWebView(session: browser).opacity(browser.state == .loaded ? 1 : 0)
                switch browser.state {
                case .loading: ProgressView("Loading Wikipedia…").controlSize(.small).emptyPanel()
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Wikipedia Unavailable", systemImage: "globe")
                    } description: { Text(message) } actions: {
                        Button("Try Again") { if let url = browser.requestedURL { browser.show(url, force: true) } }
                    }.emptyPanel()
                default: EmptyView()
                }
            }
        } else {
            ContentUnavailableView("Choose an Artist or Album", systemImage: "globe", description: Text("Play or select a track, or search Wikipedia above."))
                .emptyPanel()
        }
    }

    private func followTarget() {
        search = WikipediaLookup.query(for: model.playingContextTrack, topic: topic) ?? ""
        if let url = WikipediaLookup.searchURL(for: search) { browser.show(url) }
        else { browser.hide() }
    }
    private func submit() { if let url = WikipediaLookup.searchURL(for: search) { browser.show(url, force: true) } }
}

private struct WikipediaWebView: NSViewRepresentable {
    let session: WikipediaBrowserSession
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        session.bind(owner: context.coordinator.id) { [weak view] in view?.stopLoading() }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        guard session.isVisible, let url = session.requestedURL else { view.stopLoading(); return }
        guard coordinator.loadedGeneration != session.generation else { return }
        coordinator.begin(generation: session.generation)
        view.stopLoading()
        if let navigation = view.load(URLRequest(url: url)) { coordinator.generations[ObjectIdentifier(navigation)] = session.generation }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil
        coordinator.session.unbind(owner: coordinator.id)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        let id = UUID()
        let session: WikipediaBrowserSession
        var loadedGeneration: UUID?
        var generations: [ObjectIdentifier: UUID] = [:]
        private var userNavigationGeneration: UUID?
        init(session: WikipediaBrowserSession) { self.session = session }
        func begin(generation: UUID) {
            loadedGeneration = generation; generations.removeAll(); userNavigationGeneration = nil
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard session.isVisible else { decisionHandler(.cancel); return }
            let userInitiated = [.linkActivated, .formSubmitted, .backForward].contains(navigationAction.navigationType)
            switch WikipediaLookup.navigation(for: navigationAction.request.url, userInitiated: userInitiated) {
            case .inline:
                if userInitiated { userNavigationGeneration = session.generation }
                if navigationAction.targetFrame == nil, userInitiated {
                    if let navigation = webView.load(navigationAction.request) { generations[ObjectIdentifier(navigation)] = session.generation }
                    decisionHandler(.cancel)
                } else { decisionHandler(.allow) }
            case .external:
                if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            case .cancel: decisionHandler(.cancel)
            }
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard let navigation else { return }
            let key = ObjectIdentifier(navigation)
            if generations[key] == nil, let generation = userNavigationGeneration {
                generations[key] = generation; userNavigationGeneration = nil
            }
            if let generation = generations[key] { session.started(generation: generation, url: webView.url) }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let navigation, let generation = generations.removeValue(forKey: ObjectIdentifier(navigation)) else { return }
            session.finished(generation: generation, url: webView.url)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(navigation, error: error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(navigation, error: error) }
        private func fail(_ navigation: WKNavigation?, error: Error) {
            guard let navigation, let generation = generations.removeValue(forKey: ObjectIdentifier(navigation)) else { return }
            guard (error as? URLError)?.code != .cancelled else { return }
            session.failed(generation: generation, message: error.localizedDescription)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if let generation = loadedGeneration { session.failed(generation: generation, message: "The Wikipedia page stopped responding. Try again.") }
        }
    }
}
