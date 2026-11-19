import MacarokCore
import SwiftUI

struct LibraryPane: View {
    @Bindable var model: AppModel
    @State private var expandedArtists: Set<String> = []
    @State private var expandedAlbums: Set<String> = []
    @State private var expandedYears: Set<Int> = []
    @State private var expandedGenres: Set<String> = []
    @State private var expandedFormats: Set<String> = []
    @FocusState private var searchFocused: Bool
    private var visibleRadioStations: [RadioStationRecord] { model.radioStations.filter { !model.search.isEmpty || $0.isFavorite } }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader { SourceMenu(model: model) }
                .accessibilityIdentifier("libraryPanelHeader")
            if model.isRadioSource {
                RadioLibraryView(model: model)
            } else if model.libraryScope == .podcasts {
                PodcastHubView(model: model, directory: model.podcastDirectory, podcasts: model.podcasts)
            } else if let source = model.selectedSource, source.kind == .internetArchive, let archive = model.archive {
                ArchiveLibraryView(model: model, controller: archive, source: source)
            } else if let source = model.selectedSource, source.kind == .podcasts {
                PodcastSourceLibraryView(model: model, source: source)
            } else {
            VStack(spacing: 0) {
            VStack(spacing: 9) {
                SearchField(prompt: model.isAllSources ? "Search all sources" : "Search this library", text: $model.search, focus: $searchFocused)
                LibraryViewPicker(model: model)
            }.padding(.horizontal, 12).padding(.vertical, 10)
            if model.libraryView == .podcasts {
                PodcastLibraryView(model: model, podcasts: model.podcasts)
            } else {
            LibraryListHeader(model: model, title: listTitle, count: listCount, sortEnabled: !model.tracks.isEmpty)
            .contextMenu {
                Button(model.libraryView == .folders ? "Shuffle Selected Folder" : "Shuffle Library") { model.shuffle(shuffleScope) }
                    .disabled(shuffleScope.isEmpty)
                ServerScanMenuItems(model: model)
            }
            if model.sources.isEmpty {
                ContentUnavailableView {
                    Label("Bring Your Music", systemImage: "music.note.house")
                } actions: {
                    Button("Add Music Folder…", action: model.pickFolder)
                    Button("Connect a Source…") { model.presentAddSource(from: .mainWindow) }
                }.emptyPanel()
            } else if (model.isLoadingLibrary && model.tracks.isEmpty) || (model.isSearching && model.displayedTracks.isEmpty) {
                ProgressView(model.isSearching ? "Searching library…" : "Loading library…")
                    .controlSize(.small).emptyPanel()
            } else if model.displayedTracks.isEmpty && visibleRadioStations.isEmpty && !model.podcastEpisodes.isEmpty {
                // All Sources keeps podcasts out of the music lists; point to where they are.
                ContentUnavailableView {
                    Label(model.search.isEmpty ? "No Music" : "No Matching Music", systemImage: "music.note")
                } description: {
                    Text(model.search.isEmpty ? "Your podcasts are in the Podcasts tab." : "Matching podcast episodes are in the Podcasts tab.")
                } actions: {
                    Button("Show Podcasts") { model.selectLibraryView(.podcasts) }
                }.emptyPanel()
            } else if model.displayedTracks.isEmpty && visibleRadioStations.isEmpty {
                ContentUnavailableView.search(text: model.search)
                    .emptyPanel()
            } else {
                List(selection: Binding(get: { model.librarySelection }, set: { model.selectLibraryItem($0) })) {
                    if model.isAllSources && !visibleRadioStations.isEmpty {
                        Section(model.search.isEmpty ? "Radio Favorites" : "Radio Stations") {
                            ForEach(visibleRadioStations) { station in
                                RadioStationLabel(station: station).contentShape(Rectangle())
                                    .onTapGesture(count: 2) { Task { await model.radio?.addToPlaylist(station, playNow: model.queue.isEmpty) } }
                                    .contextMenu { if let controller = model.radio { RadioStationActions(controller: controller, station: station) } }
                            }
                        }
                    }
                    switch model.libraryView {
                    case .home, .artists:
                        ForEach(model.artists) { artist in
                            DisclosureGroup(isExpanded: expansion(artist.id, in: $expandedArtists)) {
                                if expandedArtists.contains(artist.id) {
                                    ForEach(artist.albums, id: \.presentationID) { album in
                                        DisclosureGroup(isExpanded: expansion(album.presentationID, in: $expandedAlbums)) {
                                            if expandedAlbums.contains(album.presentationID) {
                                                ForEach(album.tracks) { libraryTrack($0) }
                                            }
                                        } label: { albumLabel(album) }
                                        .libraryItem(.album(album.presentationID))
                                    }
                                }
                            } label: {
                                HStack { Text(artist.name).lineLimit(1); SourceGroupBadge(model: model, sourceIDs: artist.sourceIDs); Spacer(); Text("\(artist.albums.count)").font(.system(size: 10)).foregroundStyle(.tertiary) }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    .contextMenu {
                                        LibraryPlaybackActions(model: model, addTitle: "Add Artist to Playlist") { model.albumsForArtist(artist.name).flatMap(\.tracks) }
                                        Button("Shuffle Artist") { model.shuffle(model.albumsForArtist(artist.name).flatMap(\.tracks)) }
                                    }
                            }
                            .libraryItem(.artist(LibraryArtistGroup.normalizedName(artist.name)))
                        }
                    case .albums:
                        ForEach(model.visibleAlbums, id: \.presentationID) { album in albumRow(album).libraryItem(.album(album.presentationID)) }
                    case .years:
                        ForEach(model.yearGroups) { group in
                            DisclosureGroup(isExpanded: expansion(group.id, in: $expandedYears)) {
                                if expandedYears.contains(group.id) {
                                    ForEach(group.albums, id: \.presentationID) { albumRow($0).libraryItem(.album($0.presentationID)) }
                                }
                            } label: { Text(group.title).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                        }
                    case .folders:
                        FolderLibrary(model: model)
                    case .podcasts:
                        EmptyView()
                    case .tags:
                        Section("Genre") {
                            ForEach(model.genreGroups) { group in
                                DisclosureGroup(isExpanded: expansion(group.id, in: $expandedGenres)) {
                                    if expandedGenres.contains(group.id) {
                                        ForEach(group.tracks) { libraryTrack($0, showsArtist: true) }
                                    }
                                } label: { Text(group.title).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                            }
                        }
                        Section("Format") {
                            ForEach(model.formatGroups) { group in
                                DisclosureGroup(isExpanded: expansion(group.id, in: $expandedFormats)) {
                                    if expandedFormats.contains(group.id) {
                                        ForEach(group.tracks) { libraryTrack($0, showsArtist: true) }
                                    }
                                } label: { Text(group.title).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                            }
                        }
                    }
                }.listStyle(.inset(alternatesRowBackgrounds: true)).environment(\.defaultMinListRowHeight, 25)
                    // Row menus stay on each row; the list owns selection, double-click/Return, and dragging.
                    .contextMenu(forSelectionType: LibraryItemID.self, menu: { _ in EmptyView() },
                                 primaryAction: { items in items.forEach(model.activateLibraryItem) })
                    .background(NativeListBackground(revision: rowBackgroundRevision))
            }
            LibraryPanelFooter(model: model, summary: .music(albums: model.albums.count, tracks: model.tracks.count))
            }
            }
            }
        }.background(.regularMaterial)
        .onReceive(NotificationCenter.default.publisher(for: .macarokFocusSearch)) { _ in searchFocused = true }
        .onChange(of: model.contextPage) { _, _ in searchFocused = false }
        .onChange(of: model.selectedTrackID) { _, _ in searchFocused = false }
        .onChange(of: model.selectedAlbumID) { _, _ in searchFocused = false }
        .onChange(of: model.selectedArtist) { _, _ in searchFocused = false }
        .onChange(of: model.selectedQueueID) { _, _ in searchFocused = false }
        .onChange(of: model.queue.count) { _, _ in searchFocused = false }
        .onChange(of: model.libraryScope) { _, _ in
            expandedArtists = []; expandedAlbums = []; expandedYears = []; expandedGenres = []; expandedFormats = []
        }
    }

    private var listTitle: String {
        guard model.search.isEmpty else { return "Search Results" }
        return model.libraryView == .home ? "Your Library" : model.libraryView.title
    }

    /// Items at the top level of the current list; Folders browse a tree and show no total.
    private var listCount: Int? {
        if model.tracks.isEmpty { return nil }
        if !model.search.isEmpty { return model.displayedTracks.count }
        switch model.libraryView {
        case .home, .artists: return model.artists.count
        case .albums: return model.visibleAlbums.count
        case .years: return model.yearGroups.count
        case .tags: return model.genreGroups.count
        case .folders, .podcasts: return nil
        }
    }

    private var shuffleScope: [TrackRecord] { model.libraryView == .folders ? model.folderTracks : model.displayedTracks }

    private var rowBackgroundRevision: Int {
        var value = Hasher()
        value.combine(model.libraryRevision); value.combine(model.search); value.combine(model.displayedTracks.count)
        value.combine(model.libraryView.rawValue)
        value.combine(expandedArtists); value.combine(expandedAlbums); value.combine(expandedYears)
        value.combine(expandedGenres); value.combine(expandedFormats)
        return value.finalize()
    }

    private func expansion<ID: Hashable>(_ id: ID, in values: Binding<Set<ID>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(id) }, set: { expanded in
            if expanded { values.wrappedValue.insert(id) }
            else { values.wrappedValue.remove(id) }
        })
    }

    private func libraryTrack(_ track: TrackRecord, showsArtist: Bool = false) -> some View {
        TrackLine(track: track, model: model, showsArtist: showsArtist, usesListSelection: true).libraryItem(.track(track.id))
    }

    private func albumLabel(_ album: AlbumRecord) -> some View {
        HStack { Text(album.title).lineLimit(1); SourceBadge(model: model, sourceID: album.sourceID); Spacer(); Text(album.year.map(String.init) ?? "").font(.system(size: 10)).foregroundStyle(.tertiary) }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .contextMenu {
                LibraryPlaybackActions(model: model, addTitle: "Add Album to Playlist") { model.tracksForAlbum(album) }; AlbumMetadataAction(model: model, album: album)
                Button("Shuffle Album") { model.shuffle(model.tracksForAlbum(album)) }
            }
    }

    private func albumRow(_ album: AlbumRecord) -> some View {
        HStack(spacing: 9) { ArtworkView(track: album.tracks.first, model: model).frame(width: 36, height: 36); VStack(alignment: .leading, spacing: 2) { Text(album.title).lineLimit(1); Text("\(album.artist) · \(album.year.map(String.init) ?? "—")").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1); SourceBadge(model: model, sourceID: album.sourceID) } }.font(.system(size: 12)).padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .contextMenu {
                LibraryPlaybackActions(model: model, addTitle: "Add Album to Playlist") { model.tracksForAlbum(album) }; AlbumMetadataAction(model: model, album: album)
                Button("Shuffle Album") { model.shuffle(model.tracksForAlbum(album)) }
            }
    }
}

struct FolderLibrary: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            if !model.folderNodes.isEmpty {
                OutlineGroup(model.folderNodes, children: \.children) { node in
                    Label(node.name, systemImage: "folder").font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .contextMenu { Button("Shuffle Folder") { model.shuffle(model.tracksInFolder(node.id)) }; Button("Add Folder to Playlist") { model.add(model.tracksInFolder(node.id)) } }
                        .libraryItem(.folder(node.id))
                }
            }
            if model.isLoadingLibrary && model.folderNodes.isEmpty {
                ProgressView("Loading folders…").controlSize(.small).font(.caption)
            }
        }
    }
}

extension View {
    /// A selectable library row that can also be dragged into the active playlist.
    func libraryItem(_ item: LibraryItemID) -> some View {
        tag(item).itemProvider { LibraryItemID.itemProvider([item]) }
    }
}

extension Notification.Name { static let macarokFocusSearch = Notification.Name("Macarok.focusSearch") }

struct LibraryRefreshControl: View {
    @Bindable var model: AppModel
    var compact = false
    private var title: String {
        model.isStoppingRefresh ? "Stopping…" : model.isRefreshing ? "Stop Refresh" : model.isAllSources ? "Refresh All Sources" : "Refresh Source"
    }

    var body: some View {
        HStack(spacing: 7) {
            if let scan = model.serverScan, !model.isRefreshing {
                Text(scan.title).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing).layoutPriority(-1)
                    .help(scan.title).accessibilityIdentifier("serverScanProgress")
            } else { Spacer(minLength: 0) } // Refresh progress is shown in full in the window's status bar.
            Button(action: model.toggleRefresh) {
                HStack(spacing: 7) {
                    Image(systemName: model.isRefreshing ? "stop.fill" : "arrow.clockwise")
                    if !compact { Text(title).lineLimit(1).truncationMode(.tail) }
                }.font(.system(size: 11))
                    .frame(width: compact ? 22 : 126, alignment: .trailing).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.sources.isEmpty || model.isStoppingRefresh)
                .fixedSize(horizontal: true, vertical: false)
                .help(model.isRefreshing && !model.refreshProgress.isEmpty ? "\(title) · \(model.refreshProgress)" : title)
                .accessibilityLabel(title)
                .accessibilityIdentifier("libraryRefreshButton")
                .contextMenu { ServerScanMenuItems(model: model) }
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                .opacity(model.isRefreshing || model.serverScan != nil ? 1 : 0).accessibilityHidden(!model.isRefreshing && model.serverScan == nil)
        }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 20)
    }
}

/// Server-side scans for OpenSubsonic sources in scope; hidden for other sources.
struct ServerScanMenuItems: View {
    @Bindable var model: AppModel

    var body: some View {
        let servers = model.serverScanSources
        if !servers.isEmpty {
            Divider()
            if model.serverScan != nil {
                Button("Stop Following Server Scan", action: model.stopServerScanMonitoring)
            } else {
                Button(servers.count == 1 ? "Scan Library on Server" : "Scan Libraries on Servers") { model.scanServerLibrary() }
                    .disabled(model.isRefreshing)
                Button(servers.count == 1 ? "Full Scan on Server" : "Full Scan on Servers") { model.scanServerLibrary(fullScan: true) }
                    .disabled(model.isRefreshing)
                    .help("Re-reads every file on the server. This can take much longer.")
            }
        }
    }
}
