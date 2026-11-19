import AppKit
import MacarokCore
import SwiftUI

/// Directory browsing for the Podcasts entry: charts and search by country and genre, and previews of shows
/// that can be played without subscribing.
@MainActor @Observable
final class PodcastDirectoryController {
    enum Sort: String, CaseIterable, Identifiable {
        case popular, titleAscending, titleDescending
        var id: String { rawValue }
        var title: String { switch self { case .popular: "Popular"; case .titleAscending: "A–Z"; case .titleDescending: "Z–A" } }
    }

    struct Preview {
        let show: PodcastCatalogShow
        var feed: PodcastFeed?
        var episodes: [TrackRecord] = []
        var isLoading = true
        var errorMessage: String?
    }

    var query = ""
    var country = ApplePodcastCatalog.storefront(Locale.current.region?.identifier ?? "us") { didSet { if country != oldValue { load() } } }
    var genreID: Int? { didSet { if genreID != oldValue { load() } } }
    var sort: Sort = .popular
    private(set) var results: [PodcastCatalogShow] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false
    var preview: Preview?

    @ObservationIgnored private let catalog: ApplePodcastCatalog
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    init(catalog: ApplePodcastCatalog = ApplePodcastCatalog()) { self.catalog = catalog }

    var displayedResults: [PodcastCatalogShow] {
        switch sort {
        case .popular: results
        case .titleAscending: results.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .titleDescending: results.sorted { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        }
    }

    /// The arrow cycles popularity, then titles A–Z and Z–A.
    func cycleSort() {
        sort = switch sort { case .popular: .titleAscending; case .titleAscending: .titleDescending; case .titleDescending: .popular }
    }

    func loadIfNeeded() { if !hasLoaded && !isLoading { load() } }

    func load() {
        loadTask?.cancel()
        isLoading = true; errorMessage = nil
        let query = query, country = country, genreID = genreID, catalog = catalog
        loadTask = Task { [weak self] in
            do {
                let shows = query.trimmingCharacters(in: .whitespaces).isEmpty
                    ? try await catalog.top(country: country, genreID: genreID)
                    : try await catalog.search(query, country: country, genreID: genreID)
                try Task.checkCancellation()
                self?.results = shows
            } catch is CancellationError { return }
            catch { self?.errorMessage = error.localizedDescription }
            self?.isLoading = false; self?.hasLoaded = true
        }
    }

    func open(_ show: PodcastCatalogShow, model: AppModel) {
        previewTask?.cancel()
        preview = Preview(show: show)
        guard let feedURL = show.feedURL else {
            preview?.isLoading = false
            preview?.errorMessage = "This show does not publish its feed outside Apple Podcasts."
            return
        }
        previewTask = Task { [weak self, weak model] in
            guard let model else { return }
            do {
                let (feed, episodes) = try await model.previewPodcast(feedURL: feedURL)
                try Task.checkCancellation()
                guard self?.preview?.show.id == show.id else { return }
                self?.preview?.feed = feed; self?.preview?.episodes = PodcastLibrary.ordered(episodes)
            } catch is CancellationError { return }
            catch { if self?.preview?.show.id == show.id { self?.preview?.errorMessage = error.localizedDescription } }
            if self?.preview?.show.id == show.id { self?.preview?.isLoading = false }
        }
    }

    func closePreview() { previewTask?.cancel(); preview = nil }

    static func subscribedSource(feedURL: URL?, in sources: [SourceRecord]) -> SourceRecord? {
        guard let feedURL else { return nil }
        return sources.first { $0.kind == .podcasts && AppModel.samePodcastFeed($0.location, feedURL.absoluteString) }
    }
}

/// The Podcasts entry in the library: Browse the directory or the shows you subscribe to.
struct PodcastHubView: View {
    @Bindable var model: AppModel
    @Bindable var directory: PodcastDirectoryController
    @Bindable var podcasts: PodcastController

    var body: some View {
        VStack(spacing: 0) {
            if model.podcastHubMode == .browse, let preview = directory.preview {
                PodcastBackBar(title: "Browse") { directory.closePreview() }
                PodcastPreviewView(model: model, directory: directory, preview: preview)
            } else if model.podcastHubMode == .subscribed, let id = model.focusedPodcastShowID, let source = model.sourcesByID[id] {
                PodcastBackBar(title: "Subscribed") { model.closePodcastShow() }
                PodcastShowView(model: model, podcasts: podcasts, source: source).id(source.id)
            } else {
                Picker("Podcasts", selection: $model.podcastHubMode) {
                    ForEach(PodcastHubMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
                switch model.podcastHubMode {
                case .browse: PodcastBrowseView(model: model, directory: directory)
                case .subscribed: PodcastSubscribedView(model: model, podcasts: podcasts)
                }
            }
            LibraryPanelFooter(model: model, summary: .podcasts(shows: model.podcastSourcesInScope.count, episodes: model.allPodcastEpisodes.count))
        }
    }
}

struct PodcastBackBar: View {
    let title: String
    let action: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Button(action: action) {
                    HStack(spacing: 4) { Image(systemName: "chevron.left"); Text(title) }.contentShape(Rectangle())
                }.buttonStyle(.borderless).help("Back to \(title)")
                Spacer(minLength: 0)
            }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 32)
            Divider()
        }
    }
}

struct PodcastBrowseView: View {
    @Bindable var model: AppModel
    @Bindable var directory: PodcastDirectoryController
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                SearchField(prompt: "Search podcasts", text: $directory.query, focus: $searchFocused,
                            onSubmit: directory.load, onClear: directory.load)
                HStack(spacing: 6) {
                    Picker("Country", selection: $directory.country) {
                        ForEach(ApplePodcastCatalog.countries, id: \.self) { code in
                            Text(Locale.current.localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()).tag(code)
                        }
                    }.labelsHidden().help("Country of the Apple Podcasts charts")
                    Picker("Genre", selection: $directory.genreID) {
                        Text("All Genres").tag(Int?.none)
                        Divider()
                        ForEach(ApplePodcastCatalog.genres) { Text($0.title).tag(Int?.some($0.id)) }
                    }.labelsHidden()
                }.controlSize(.small)
            }.padding(.horizontal, 12).padding(.bottom, 10)
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 6) {
                    Text(directory.query.isEmpty ? "Popular" : "Results").font(.system(size: 11, weight: .semibold))
                    if !directory.results.isEmpty { Text("\(directory.results.count)").font(.system(size: 11)).foregroundStyle(.secondary) }
                    if directory.isLoading { ProgressView().controlSize(.mini) }
                    Spacer(minLength: 4)
                    Button(action: directory.cycleSort) {
                        HStack(spacing: 3) {
                            Image(systemName: directory.sort == .titleDescending ? "chevron.down" : "chevron.up").font(.system(size: 9, weight: .semibold))
                            Text(directory.sort.title)
                        }.font(.system(size: 10)).foregroundStyle(.secondary).frame(minHeight: 18).contentShape(Rectangle())
                    }.buttonStyle(.borderless).help("Sort by popularity, then by title")
                }.padding(.horizontal, 14).frame(height: 26).background(Color(nsColor: .textBackgroundColor))
                Divider().opacity(0.5)
            }
            content
        }
        .onAppear { directory.loadIfNeeded() }
    }

    @ViewBuilder private var content: some View {
        if let error = directory.errorMessage, directory.results.isEmpty {
            ContentUnavailableView {
                Label("Directory Unavailable", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: { Button("Try Again", action: directory.load) }.emptyPanel()
        } else if directory.results.isEmpty {
            if directory.isLoading || !directory.hasLoaded { ProgressView("Loading podcasts…").controlSize(.small).emptyPanel() }
            else { ContentUnavailableView.search(text: directory.query).emptyPanel() }
        } else {
            List(directory.displayedResults) { show in
                PodcastCatalogRow(show: show, subscribed: PodcastDirectoryController.subscribedSource(feedURL: show.feedURL, in: model.sources) != nil)
                    .contentShape(Rectangle())
                    .onTapGesture { directory.open(show, model: model) }
                    .accessibilityAddTraits(.isButton).accessibilityAction { directory.open(show, model: model) }
            }.listStyle(.inset(alternatesRowBackgrounds: true))
                .background(NativeListBackground(revision: directory.displayedResults.map(\.id).hashValue))
        }
    }
}

struct PodcastCatalogRow: View {
    let show: PodcastCatalogShow
    let subscribed: Bool
    var body: some View {
        HStack(spacing: 9) {
            DirectoryArtwork(url: show.artworkURL, symbol: "mic").frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(show.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if !show.author.isEmpty { Text(show.author).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                Text(details).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if subscribed { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).help("Subscribed") }
            else if show.feedURL == nil { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.tertiary).help("Only available in Apple Podcasts") }
        }.padding(.vertical, 2)
    }

    private var details: String {
        [show.genre, show.episodeCount.map { $0 == 1 ? "1 episode" : "\($0) episodes" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Subscribed shows as a grid of artwork, plus the New, In Progress, and Downloaded episode lists.
struct PodcastSubscribedView: View {
    @Bindable var model: AppModel
    @Bindable var podcasts: PodcastController

    var body: some View {
        VStack(spacing: 0) {
            if model.podcastSourcesInScope.isEmpty {
                ContentUnavailableView {
                    Label { Text("No Subscriptions") } icon: { Image.podcastLarge }
                } description: { Text("Find shows in Browse and subscribe to follow their new episodes.") } actions: {
                    Button("Browse Podcasts") { model.podcastHubMode = .browse }
                }.emptyPanel()
            } else {
                Picker("Filter", selection: $podcasts.hubSegment) {
                    ForEach(PodcastHubSegment.allCases) { Text($0 == .shows ? "All" : $0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().controlSize(.small).padding(.horizontal, 12).padding(.bottom, 8)
                Divider()
                switch podcasts.hubSegment {
                case .shows: grid
                case .new:
                    PodcastEpisodeList(model: model, podcasts: podcasts, episodes: model.newPodcastEpisodes(), showsShowName: true,
                                       emptyTitle: "No New Episodes", emptyDetail: "Unplayed episodes from the last 30 days appear here.")
                case .inProgress:
                    PodcastEpisodeList(model: model, podcasts: podcasts, episodes: model.inProgressPodcastEpisodes(), showsShowName: true,
                                       emptyTitle: "Nothing in Progress", emptyDetail: "Episodes you started appear here until you finish them.")
                case .downloaded:
                    PodcastEpisodeList(model: model, podcasts: podcasts, episodes: model.podcastEpisodes(showID: nil, filter: .downloaded), showsShowName: true,
                                       emptyTitle: "No Downloads", emptyDetail: "Download an episode to listen without streaming.")
                }
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86, maximum: 120), spacing: 10)], spacing: 10) {
                ForEach(model.podcastShowSummaries) { show in
                    PodcastShowTile(model: model, show: show)
                }
            }.padding(12)
        }.background(Color(nsColor: .textBackgroundColor))
    }
}

struct PodcastShowTile: View {
    @Bindable var model: AppModel
    let show: PodcastShowSummary
    @State private var hovering = false
    @State private var confirmsUnsubscribe = false

    var body: some View {
        ArtworkView(track: show.latestEpisode, model: model, cornerRadius: 0)
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .bottom) {
                if hovering {
                    Text(show.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                        .multilineTextAlignment(.center).padding(5).frame(maxWidth: .infinity).background(.black.opacity(0.62))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay { if hovering { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2) } }
            .overlay(alignment: .topTrailing) {
                if show.unplayedCount > 0 {
                    Circle().fill(Color.accentColor).frame(width: 9, height: 9).padding(5).help("\(show.unplayedCount) unplayed")
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { model.openPodcastShow(show.id) }
            .help(show.title)
            .accessibilityElement().accessibilityLabel(show.title).accessibilityAddTraits(.isButton)
            .accessibilityAction { model.openPodcastShow(show.id) }
            .contextMenu {
                if let latest = show.latestEpisode { Button("Play Latest Episode") { model.add([latest], play: true) } }
                PodcastShowActions(model: model, sourceID: show.id, confirmsUnsubscribe: $confirmsUnsubscribe)
            }
            .podcastUnsubscribeDialog(model: model, sourceID: show.id, isPresented: $confirmsUnsubscribe)
    }
}

/// The show page's header: artwork, title, author and details, shared by subscribed and previewed shows.
struct PodcastShowHeader<Artwork: View>: View {
    let title: String
    let author: String
    let details: String
    let summary: String
    @ViewBuilder let artwork: Artwork
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                artwork.frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(3)
                    if !author.isEmpty { Text(author).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                    if !details.isEmpty { Text(details).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2) }
                }
                Spacer(minLength: 0)
            }
            if !summary.isEmpty {
                Text(summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(expanded ? nil : 4)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if summary.count > 220 {
                    Button(expanded ? "Less" : "More") { expanded.toggle() }.buttonStyle(.link).font(.system(size: 11))
                }
            }
        }
    }
}

/// Only the latest episodes are listed at first: a long back catalogue says little about a show.
enum PodcastEpisodePreview {
    static let count = 10
}

/// A directory show before subscribing: its latest episodes can be played right away.
struct PodcastPreviewView: View {
    @Bindable var model: AppModel
    @Bindable var directory: PodcastDirectoryController
    let preview: PodcastDirectoryController.Preview
    @State private var showsAll = false

    var body: some View {
        let subscribed = PodcastDirectoryController.subscribedSource(feedURL: preview.feed?.url ?? preview.show.feedURL, in: model.sources)
        VStack(alignment: .leading, spacing: 0) {
            PodcastShowHeader(title: preview.feed?.title ?? preview.show.title, author: preview.feed?.author ?? preview.show.author,
                              details: details, summary: preview.feed?.description ?? "") {
                DirectoryArtwork(url: preview.feed?.artworkURL ?? preview.show.artworkURL, symbol: "mic")
            }.padding(.horizontal, 12).padding(.top, 12)
            HStack(spacing: 8) {
                if let subscribed {
                    Button { model.podcastHubMode = .subscribed; model.openPodcastShow(subscribed.id); directory.closePreview() } label: {
                        Label("Subscribed", systemImage: "checkmark")
                    }.help("Open the show in Subscribed")
                } else {
                    Button { subscribe() } label: { Label("Subscribe", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).disabled(preview.feed == nil)
                }
                if let latest = preview.episodes.first {
                    Button { model.add([latest], play: true) } label: { Label("Play Latest", systemImage: "play.fill") }
                        .help("Play “\(latest.title)”")
                }
                if let link = preview.feed?.link {
                    Button { NSWorkspace.shared.open(link) } label: { Image(systemName: "safari") }.help("Open Website")
                }
                Spacer(minLength: 0)
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 10)
            episodes
        }
    }

    @ViewBuilder private var episodes: some View {
        if let error = preview.errorMessage {
            ContentUnavailableView { Label("Show Unavailable", systemImage: "exclamationmark.triangle") } description: { Text(error) }.emptyPanel()
        } else if preview.isLoading {
            ProgressView("Loading episodes…").controlSize(.small).emptyPanel()
        } else {
            let shown = showsAll ? preview.episodes : Array(preview.episodes.prefix(PodcastEpisodePreview.count))
            PodcastListHeader(model: model, title: showsAll ? "Episodes" : "Latest Episodes", count: preview.episodes.count)
            PodcastEpisodeList(model: model, podcasts: model.podcasts, episodes: shown, showsShowName: false,
                               emptyTitle: "No Episodes", emptyDetail: "This feed has no playable episodes.")
            if !showsAll && preview.episodes.count > shown.count {
                Button("Show All \(preview.episodes.count) Episodes") { showsAll = true }
                    .buttonStyle(.link).font(.system(size: 11)).frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    private var details: String {
        let count = preview.feed.map { $0.episodes.count } ?? preview.show.episodeCount
        return [preview.show.genre, count.map { $0 == 1 ? "1 episode" : "\($0) episodes" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func subscribe() {
        guard let url = preview.feed?.url ?? preview.show.feedURL else { return }
        Task {
            do {
                try await model.addPodcast(address: url.absoluteString)
                model.podcastHubMode = .subscribed
                directory.closePreview()
            } catch { model.fail("Could not subscribe", error.localizedDescription) }
        }
    }
}
