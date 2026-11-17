import AppKit
import MacarokAudio
import MacarokCore
import SwiftUI

/// The Podcasts library tab: a hub of shows and episode lists, with shows opened in place.
struct PodcastLibraryView: View {
    @Bindable var model: AppModel
    @Bindable var podcasts: PodcastController

    var body: some View {
        VStack(spacing: 0) {
            if model.podcastSourcesInScope.isEmpty {
                PodcastEmptyState(model: model)
            } else if let id = model.focusedPodcastShowID, let source = model.sourcesByID[id] {
                HStack(spacing: 6) {
                    Button { model.closePodcastShow() } label: { Image(systemName: "chevron.left").frame(width: 20, height: 18).contentShape(Rectangle()) }
                        .buttonStyle(.borderless).help("Back to Podcasts").accessibilityLabel("Back to Podcasts")
                    Text(source.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 12).padding(.bottom, 6)
                PodcastShowView(model: model, podcasts: podcasts, source: source).id(source.id)
            } else {
                Picker("Podcasts view", selection: $podcasts.hubSegment) {
                    ForEach(PodcastHubSegment.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.bottom, 8)
                PodcastListHeader(model: model, title: model.search.isEmpty ? podcasts.hubSegment.title : "Search Results", count: hubCount)
                hubContent
            }
            LibraryPanelFooter(model: model, summary: .podcasts(shows: model.podcastSourcesInScope.count, episodes: model.allPodcastEpisodes.count))
        }
    }

    @ViewBuilder private var hubContent: some View {
        switch podcasts.hubSegment {
        case .shows:
            let shows = model.podcastShowSummaries
            if shows.isEmpty { emptyList("No Matching Shows", "Try another search.") }
            else {
                List(shows) { show in
                    PodcastShowRow(model: model, podcasts: podcasts, show: show)
                }.listStyle(.inset(alternatesRowBackgrounds: true))
                    .background(NativeListBackground(revision: shows.map(\.id).hashValue))
            }
        case .new:
            PodcastEpisodeList(model: model, podcasts: podcasts, episodes: model.newPodcastEpisodes(), showsShowName: true,
                               emptyTitle: "No New Episodes", emptyDetail: "Unplayed episodes from the last 30 days appear here.")
        case .inProgress:
            PodcastEpisodeList(model: model, podcasts: podcasts, episodes: model.inProgressPodcastEpisodes().filter(isVisible), showsShowName: true,
                               emptyTitle: "Nothing in Progress", emptyDetail: "Episodes you started appear here until you finish them.")
        case .downloaded:
            PodcastEpisodeList(model: model, podcasts: podcasts, episodes: model.podcastEpisodes(showID: nil, filter: .downloaded), showsShowName: true,
                               emptyTitle: "No Downloads", emptyDetail: "Download an episode to listen without streaming.")
        }
    }

    private var hubCount: Int {
        switch podcasts.hubSegment {
        case .shows: model.podcastShowSummaries.count
        case .new: model.newPodcastEpisodes().count
        case .inProgress: model.inProgressPodcastEpisodes().filter(isVisible).count
        case .downloaded: model.podcastEpisodes(showID: nil, filter: .downloaded).count
        }
    }

    /// Search narrows In Progress the same way as the other episode lists.
    private func isVisible(_ track: TrackRecord) -> Bool { model.search.isEmpty || model.podcastEpisodes.contains { $0.id == track.id } }

    private func emptyList(_ title: String, _ detail: String) -> some View {
        ContentUnavailableView { Label { Text(title) } icon: { Image.podcastLarge } } description: { Text(detail) }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A selected podcast source shows its episodes directly, with the library search above them.
struct PodcastSourceLibraryView: View {
    @Bindable var model: AppModel
    let source: SourceRecord
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SearchField(prompt: "Search this show", text: $model.search, focus: $searchFocused).padding(12)
            PodcastShowView(model: model, podcasts: model.podcasts, source: source).id(source.id)
            LibraryPanelFooter(model: model, summary: .podcasts(shows: 1, episodes: model.allPodcastEpisodes.count))
        }
        .onReceive(NotificationCenter.default.publisher(for: .macarokFocusSearch)) { _ in searchFocused = true }
    }
}

struct PodcastListHeader: View {
    @Bindable var model: AppModel
    let title: String
    var count: Int?

    var body: some View { LibraryListHeader(model: model, title: title, count: count) }
}

struct PodcastEmptyState: View {
    @Bindable var model: AppModel
    @State private var showsDiscovery = false

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: PodcastSourceIcon.make(size: 32)).renderingMode(.template).foregroundStyle(.tertiary)
            Text("No Podcasts").foregroundStyle(.secondary)
            Button("Search Podcasts…") { showsDiscovery = true }
            Button("Add Feed URL…") { model.presentAddSource(from: .mainWindow) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $showsDiscovery) {
                PodcastDiscoverySheet { result in
                    Task {
                        do { try await model.addPodcast(address: result.feedURL.absoluteString) }
                        catch { model.fail("Could not subscribe", error.localizedDescription) }
                    }
                }
            }
    }
}

struct PodcastShowRow: View {
    @Bindable var model: AppModel
    @Bindable var podcasts: PodcastController
    let show: PodcastShowSummary
    @State private var confirmsUnsubscribe = false

    var body: some View {
        HStack(spacing: 9) {
            ArtworkView(track: show.latestEpisode, model: model).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(show.title).lineLimit(1)
                Text(details).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let error = podcasts.shows[show.id]?.lastError {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.secondary).help(error)
            }
            if show.unplayedCount > 0 {
                Text("\(show.unplayedCount)").font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .padding(.horizontal, 5).padding(.vertical, 1).background(Color.accentColor.opacity(0.18), in: Capsule())
                    .help("\(show.unplayedCount) unplayed")
            }
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
        }.font(.system(size: 12)).padding(.vertical, 3).contentShape(Rectangle())
            .onTapGesture { model.openPodcastShow(show.id) }
            .accessibilityAddTraits(.isButton).accessibilityAction { model.openPodcastShow(show.id) }
            .contextMenu {
                if let latest = show.latestEpisode { Button("Play Latest Episode") { model.add([latest], play: true) } }
                PodcastShowActions(model: model, sourceID: show.id, confirmsUnsubscribe: $confirmsUnsubscribe)
            }
            .podcastUnsubscribeDialog(model: model, sourceID: show.id, isPresented: $confirmsUnsubscribe)
    }

    private var details: String {
        let count = show.episodeCount == 1 ? "1 episode" : "\(show.episodeCount) episodes"
        return show.latestDate.map { "\(count) · \(PodcastDate.short($0))" } ?? count
    }
}

/// Actions shared by a show's row menu and its header menu.
struct PodcastShowActions: View {
    @Bindable var model: AppModel
    let sourceID: String
    @Binding var confirmsUnsubscribe: Bool

    var body: some View {
        Button("Mark All as Played") { model.podcasts.setPlayed(true, tracks: model.showEpisodes(sourceID)) }
        Button("Refresh Show") { model.refresh(sourceID: sourceID) }.disabled(model.isRefreshing)
        Divider()
        Button("Copy Feed URL") { model.copyFeedURL(sourceID) }
        if let link = model.podcasts.shows[sourceID]?.link.flatMap(URL.init(string:)) {
            Button("Open Website") { NSWorkspace.shared.open(link) }
        }
        Divider()
        Button("Unsubscribe…", role: .destructive) { confirmsUnsubscribe = true }
    }
}

extension View {
    func podcastUnsubscribeDialog(model: AppModel, sourceID: String, isPresented: Binding<Bool>) -> some View {
        confirmationDialog("Unsubscribe from \(model.sourcesByID[sourceID]?.name ?? "this show")?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Unsubscribe", role: .destructive) { if let source = model.sourcesByID[sourceID] { model.removeSource(source) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its episodes leave your library and playlist. Completed downloads stay until you remove them.")
        }
    }
}

/// One show: header with actions, the All / Unplayed / Downloaded filter, and its episodes.
struct PodcastShowView: View {
    @Bindable var model: AppModel
    @Bindable var podcasts: PodcastController
    let source: SourceRecord
    @State private var confirmsUnsubscribe = false

    var body: some View {
        let episodes = model.podcastEpisodes(showID: source.id, filter: podcasts.episodeFilter)
        let all = model.showEpisodes(source.id)
        let resume = model.inProgressPodcastEpisodes(showID: source.id, limit: 1).first
        let latest = PodcastLibrary.ordered(all).first
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                ArtworkView(track: latest, model: model).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(podcasts.shows[source.id]?.title ?? source.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    if let author = podcasts.shows[source.id]?.author ?? all.first?.artist, !author.isEmpty {
                        Text(author).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(all.count == 1 ? "1 episode" : "\(all.count) episodes").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 12)
            HStack(spacing: 10) {
                if let resume, case let .inProgress(_, remaining) = podcasts.state(resume) {
                    Button { model.add([resume], play: true) } label: { Label("Resume", systemImage: "play.fill") }
                        .help("Continue “\(resume.title)” · \(PodcastDate.remaining(remaining))")
                }
                if let latest {
                    Button { model.add([latest], play: true) } label: { Label("Play Latest", systemImage: "play") }
                        .help("Play “\(latest.title)”")
                }
                Button { model.add(model.unplayedEpisodes(showID: source.id)) } label: { Label("Add Unplayed", systemImage: "text.badge.plus") }
                    .help("Add unplayed episodes to the active playlist, oldest first")
                    .disabled(all.allSatisfy { !podcasts.state($0).isUnplayed })
                Spacer(minLength: 0)
                Menu {
                    PodcastShowActions(model: model, sourceID: source.id, confirmsUnsubscribe: $confirmsUnsubscribe)
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("More actions")
            }.buttonStyle(.borderless).font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 8)
            if let error = podcasts.shows[source.id]?.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).padding(.horizontal, 12).padding(.bottom, 6)
            }
            Picker("Episodes", selection: $podcasts.episodeFilter) {
                ForEach(PodcastEpisodeFilter.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.bottom, 8)
            PodcastListHeader(model: model, title: model.search.isEmpty ? "Episodes" : "Search Results", count: episodes.count)
            PodcastEpisodeList(model: model, podcasts: podcasts, episodes: episodes, showsShowName: false,
                               emptyTitle: emptyTitle, emptyDetail: emptyDetail)
        }
        .podcastUnsubscribeDialog(model: model, sourceID: source.id, isPresented: $confirmsUnsubscribe)
    }

    private var emptyTitle: String {
        if !model.search.isEmpty { return "No Matching Episodes" }
        switch podcasts.episodeFilter {
        case .all: return "No Episodes"
        case .unplayed: return "All Caught Up"
        case .downloaded: return "No Downloads"
        }
    }

    private var emptyDetail: String {
        if !model.search.isEmpty { return "Try another search." }
        switch podcasts.episodeFilter {
        case .all: return "Refresh the show to load its episodes."
        case .unplayed: return "You have heard every episode of this show."
        case .downloaded: return "Download an episode to listen without streaming."
        }
    }
}

/// A selectable episode list sharing the library's selection, activation, and dragging.
struct PodcastEpisodeList: View {
    @Bindable var model: AppModel
    @Bindable var podcasts: PodcastController
    let episodes: [TrackRecord]
    let showsShowName: Bool
    let emptyTitle: String
    let emptyDetail: String

    var body: some View {
        if episodes.isEmpty {
            ContentUnavailableView { Label { Text(emptyTitle) } icon: { Image.podcastLarge } } description: { Text(emptyDetail) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: Binding(get: { model.librarySelection }, set: { model.selectLibraryItem($0) })) {
                ForEach(episodes) { episode in
                    PodcastEpisodeRow(model: model, podcasts: podcasts, track: episode, showsShowName: showsShowName)
                        .libraryItem(.track(episode.id))
                }
            }.listStyle(.inset(alternatesRowBackgrounds: true)).environment(\.defaultMinListRowHeight, 25)
                .contextMenu(forSelectionType: LibraryItemID.self, menu: { _ in EmptyView() },
                             primaryAction: { items in items.forEach(model.activateLibraryItem) })
                .background(NativeListBackground(revision: episodes.map(\.id).hashValue))
        }
    }
}

struct PodcastEpisodeRow: View {
    @Bindable var model: AppModel
    @Bindable var podcasts: PodcastController
    let track: TrackRecord
    var showsShowName = false
    @State private var notes: String?

    var body: some View {
        let state = podcasts.state(track)
        HStack(spacing: 7) {
            Circle().fill(state.isUnplayed ? Color.accentColor : .clear).frame(width: 6, height: 6).frame(width: 8)
                .accessibilityLabel(state.isUnplayed ? "Unplayed" : "")
            if showsShowName { ArtworkView(track: track, model: model).frame(width: 30, height: 30) }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1).foregroundStyle(state == .played ? .secondary : .primary)
                Text(subtitle(state)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                if case let .inProgress(position, remaining) = state, position + remaining > 0 {
                    ProgressView(value: position, total: position + remaining).progressViewStyle(.linear).controlSize(.mini).tint(.accentColor).frame(maxWidth: 120)
                }
            }
            Spacer(minLength: 4)
            status
            Text(state.isInProgress ? "" : track.duration > 0 ? track.formattedDuration : "").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
        }.font(.system(size: 12)).padding(.vertical, 3).contentShape(Rectangle())
            .help(notes ?? "")
            .task(id: track.id) { notes = await podcasts.notes(for: track).map { String($0.prefix(300)) } }
            .contextMenu { PodcastEpisodeMenu(model: model, track: track) }
    }

    private func subtitle(_ state: PodcastEpisodeState) -> String {
        var parts: [String] = []
        if showsShowName { parts.append(track.album) }
        if let date = PodcastDate.short(track) { parts.append(date) }
        if case let .inProgress(_, remaining) = state { parts.append(PodcastDate.remaining(remaining)) }
        return parts.joined(separator: " · ")
    }

    /// At most one status, by priority: playing, downloading, failed, queued, downloaded.
    @ViewBuilder private var status: some View {
        let key = PodcastDownloadsController.key(track)
        let downloads = model.podcastDownloads
        if model.currentTrack?.id == track.id {
            Image(systemName: "speaker.wave.2.fill").font(.system(size: 10)).foregroundStyle(Color.accentColor).help("Now playing")
        } else if let progress = downloads?.progress[key] {
            if let fraction = progress.fraction { ProgressView(value: fraction).frame(width: 40).help("Downloading \(Int(fraction * 100))%") }
            else { ProgressView().controlSize(.mini).help("Downloading") }
        } else if let error = downloads?.errors[key] {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.secondary).help(error)
        } else if model.queue.contains(where: { $0.track.id == track.id }) {
            Image(systemName: "text.badge.plus").font(.system(size: 10)).foregroundStyle(.secondary).help("In the active playlist")
        } else if downloads?.downloads[key] != nil {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 10)).foregroundStyle(.secondary).help("Downloaded")
        }
    }
}

struct PodcastEpisodeMenu: View {
    @Bindable var model: AppModel
    let track: TrackRecord

    var body: some View {
        let state = model.podcasts.state(track)
        LibraryPlaybackActions(model: model) { [track] }
        Divider()
        if state.isInProgress { Button("Play from Beginning") { model.playFromBeginning(track) } }
        if state == .played { Button("Mark as Unplayed") { model.podcasts.setPlayed(false, tracks: [track]) } }
        else { Button("Mark as Played") { model.podcasts.setPlayed(true, tracks: [track]) } }
        if model.focusedPodcastShowID != track.sourceID { Button("Go to Show") { model.openPodcastShow(track.sourceID) } }
        TrackFileActions(model: model, track: track)
    }
}

struct PodcastEpisodeTile: View {
    @Bindable var model: AppModel
    let track: TrackRecord
    let showsShowName: Bool
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(track: track, model: model).aspectRatio(1, contentMode: .fit)
            Text(track.title).font(.system(size: 11, weight: .medium)).lineLimit(2).frame(height: 28, alignment: .topLeading)
            Text(caption).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).frame(height: 13, alignment: .topLeading)
        }.frame(maxWidth: .infinity, alignment: .topLeading).contentShape(Rectangle())
            .onLibraryClick(inspect: open, add: { model.doubleClick(track) })
            .contextMenu { PodcastEpisodeMenu(model: model, track: track) }
    }

    private var caption: String {
        if case let .inProgress(_, remaining) = model.podcasts.state(track) { return PodcastDate.remaining(remaining) }
        return [showsShowName ? track.album : nil, PodcastDate.short(track)].compactMap { $0 }.joined(separator: " · ")
    }
}

struct PodcastTileSection: View {
    @Bindable var model: AppModel
    let title: String
    let episodes: [TrackRecord]
    let showsShowName: Bool
    let open: (TrackRecord) -> Void
    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 170), spacing: 14, alignment: .top)]

    var body: some View {
        if !episodes.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                Text(title).font(.system(size: 14, weight: .semibold))
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(episodes) { episode in
                        PodcastEpisodeTile(model: model, track: episode, showsShowName: showsShowName) { open(episode) }
                    }
                }
            }
        }
    }
}

/// All Sources Home: episodes being heard and the newest unplayed episode of each show.
struct PodcastHomeSection: View {
    @Bindable var model: AppModel

    var body: some View {
        PodcastTileSection(model: model, title: "Continue Listening", episodes: model.inProgressPodcastEpisodes(limit: 8),
                           showsShowName: true) { model.openPodcastShow($0.sourceID) }
        PodcastTileSection(model: model, title: "New Episodes",
                           episodes: PodcastLibrary.latestUnplayedPerShow(model.allPodcastEpisodes, state: model.podcasts.state, limit: 8),
                           showsShowName: true) { model.openPodcastShow($0.sourceID) }
    }
}

/// The center Home of one show: large header with its description, then its episodes as tiles.
struct PodcastShowHome: View {
    @Bindable var model: AppModel
    let source: SourceRecord
    @State private var expandsDescription = false

    var body: some View {
        let show = model.podcasts.shows[source.id]
        let episodes = PodcastLibrary.ordered(model.showEpisodes(source.id))
        VStack(alignment: .leading, spacing: 23) {
            HStack(alignment: .top, spacing: 17) {
                ArtworkView(track: episodes.first, model: model).frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 5) {
                    Text("PODCAST").font(.system(size: 10, weight: .medium)).tracking(1).foregroundStyle(.secondary)
                    Text(show?.title ?? source.name).font(.system(size: 27, weight: .semibold)).lineLimit(3)
                    Text(details(show, count: episodes.count)).font(.system(size: 12)).foregroundStyle(.secondary)
                    if let description = show?.description, !description.isEmpty {
                        Text(description).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                            .lineLimit(expandsDescription ? nil : 4).padding(.top, 4)
                        Button(expandsDescription ? "Less" : "More") { expandsDescription.toggle() }.buttonStyle(.borderless).font(.system(size: 11))
                    }
                }
            }
            PodcastTileSection(model: model, title: "Continue Listening", episodes: model.inProgressPodcastEpisodes(showID: source.id, limit: 8),
                               showsShowName: false) { model.inspect($0) }
            PodcastTileSection(model: model, title: "Latest Episodes", episodes: Array(episodes.prefix(8)), showsShowName: false) { model.inspect($0) }
            if episodes.isEmpty {
                ContentUnavailableView { Label { Text("No Episodes") } icon: { Image.podcastLarge } } description: { Text("Refresh the show to load its episodes.") }
            }
        }
    }

    private func details(_ show: PodcastShowRecord?, count: Int) -> String {
        var parts: [String] = []
        if let author = show?.author, !author.isEmpty { parts.append(author) }
        if let refreshed = show?.refreshedAt {
            let date = PodcastDate.short(refreshed)
            parts.append("Updated \(["Today", "Yesterday"].contains(date) ? date.lowercased() : date)")
        }
        parts.append(count == 1 ? "1 episode" : "\(count) episodes")
        return parts.joined(separator: " · ")
    }
}

/// The Playing context of an episode: its notes from the feed instead of a generated summary.
/// Web links open in the browser; chapter times seek within the episode.
struct PodcastEpisodeNotesView: View {
    @Bindable var model: AppModel
    let track: TrackRecord
    @State private var notes: String?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About this episode").font(.system(size: 13, weight: .semibold))
            if let notes, !notes.isEmpty {
                Text(PodcastNotesFormatter.attributed(notes)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineSpacing(4).textSelection(.enabled).lineLimit(expanded ? nil : 12)
                    .environment(\.openURL, OpenURLAction { url in
                        guard let seconds = PodcastNotesFormatter.seconds(from: url) else { return .systemAction }
                        model.playEpisode(track, from: seconds)
                        return .handled
                    })
                if notes.count > 700 || notes.filter({ $0 == "\n" }).count > 10 {
                    Button(expanded ? "Less" : "More") { expanded.toggle() }.buttonStyle(.borderless).font(.system(size: 11))
                }
            } else {
                Text(fallback).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            }
        }.task(id: track.id) { expanded = false; notes = await model.podcasts.notes(for: track) }
    }

    private var fallback: String {
        let date = PodcastDate.short(track).map { ", published \(["Today", "Yesterday"].contains($0) ? $0.lowercased() : $0)" } ?? ""
        return "An episode of \(track.album)\(date)."
    }
}

enum PodcastNotesFormatter {
    static let seekScheme = "macarok-seek"
    private static let timestamp = try! NSRegularExpression(pattern: #"(?<![\d:])(?:(\d{1,2}):)?([0-5]?\d):([0-5]\d)(?![\d:])"#)

    /// Plain notes with web links and chapter times (`12:34`, `1:02:03`) made clickable.
    static func attributed(_ notes: String) -> AttributedString {
        let text = NSMutableAttributedString(string: notes)
        let whole = NSRange(location: 0, length: (notes as NSString).length)
        var linked: [NSRange] = []
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: notes, range: whole) {
                guard let url = match.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { continue }
                text.addAttribute(.link, value: url, range: match.range); linked.append(match.range)
            }
        }
        for match in timestamp.matches(in: notes, range: whole) where !linked.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
            func part(_ index: Int) -> Int { Range(match.range(at: index), in: notes).flatMap { Int(notes[$0]) } ?? 0 }
            let seconds = part(1) * 3600 + part(2) * 60 + part(3)
            text.addAttribute(.link, value: URL(string: "\(seekScheme)://\(seconds)")!, range: match.range)
        }
        return (try? AttributedString(text, including: \.foundation)) ?? AttributedString(notes)
    }

    static func seconds(from url: URL) -> Double? {
        guard url.scheme == seekScheme, let host = url.host, let value = Double(host) else { return nil }
        return value
    }
}

/// Chapters of an episode in Playing → Context; the chapter being heard is highlighted.
struct PodcastChaptersView: View {
    @Bindable var model: AppModel
    @ObservedObject var timeline: PlaybackTimeline
    let track: TrackRecord
    @State private var chapters: [PodcastChapter] = []

    var body: some View {
        let isCurrent = model.currentTrack?.id == track.id
        let position = model.seeksResumePoint ? model.restorePosition : timeline.position
        let current = isCurrent ? PodcastController.chapterIndex(chapters, at: position) : nil
        // A container that always exists, so its task runs even before any chapter is known.
        VStack(alignment: .leading, spacing: 0) {
            if !chapters.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Chapters").font(.system(size: 13, weight: .semibold))
                    ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                        HStack(spacing: 10) {
                            Text(chapter.start.playbackTime).monospacedDigit().foregroundStyle(index == current ? Color.accentColor : .secondary)
                                .frame(minWidth: 52, alignment: .trailing)
                            Text(chapter.title.isEmpty ? "Chapter \(index + 1)" : chapter.title).lineLimit(2)
                                .fontWeight(index == current ? .semibold : .regular)
                            Spacer(minLength: 4)
                            if let url = chapter.url {
                                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "link") }
                                    .buttonStyle(.borderless).help(url.absoluteString)
                            }
                        }.font(.system(size: 12)).padding(.vertical, 3).padding(.horizontal, 6)
                            .background(index == current ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                            .onTapGesture { model.playEpisode(track, from: chapter.start) }
                            .help(isCurrent ? "Jump to this chapter" : "Play from this chapter")
                            .accessibilityAddTraits(.isButton)
                    }
                }
            }
        }.task(id: track.id) {
            chapters = []
            chapters = await model.podcasts.chapters(for: track)
        }
        .onChange(of: model.podcasts.currentChapters) { _, value in if isCurrent, !value.isEmpty { chapters = value } }
    }
}
