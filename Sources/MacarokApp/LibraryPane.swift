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

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 11) {
                Picker("Source", selection: $model.sourceID) {
                    if model.sources.isEmpty { Text("No sources configured").tag(String?.none) }
                    ForEach(model.sources) { source in Label(source.name, systemImage: source.kind == .local ? "externaldrive" : source.kind == .openSubsonic ? "server.rack" : "podcasts").tag(Optional(source.id)) }
                }.labelsHidden().frame(maxWidth: .infinity).controlSize(.large)
                TextField("Search this library", text: $model.search).textFieldStyle(.roundedBorder).focused($searchFocused)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                    ForEach(LibraryView.allCases) { view in
                        Button { model.libraryView = view } label: {
                            Text(view.title)
                                .font(.system(size: 11))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(model.libraryView == view ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .foregroundStyle(model.libraryView == view ? Color.accentColor : .secondary)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(12)
            HStack {
                Text(model.search.isEmpty ? model.libraryView == .home ? "YOUR LIBRARY" : model.libraryView.title.uppercased() : "SEARCH RESULTS").font(.system(size: 10, weight: .medium)).tracking(0.7).foregroundStyle(.secondary)
                if model.isSearching { ProgressView().controlSize(.mini) }
                Spacer()
                Button { model.shuffle(shuffleScope) } label: { Image(systemName: "shuffle") }.buttonStyle(.borderless).help(model.libraryView == .folders ? "Shuffle selected folder" : "Shuffle this library").disabled(model.tracks.isEmpty)
            }.padding(.horizontal, 15).padding(.bottom, 5)
            if model.sources.isEmpty {
                VStack(spacing: 12) { Image(systemName: "music.note.house").font(.system(size: 28)).foregroundStyle(.tertiary); Text("Bring your music.").foregroundStyle(.secondary); Button("Add Music Folder…", action: model.pickFolder); Button("Connect a Source…") { model.showAddSource = true } }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if (model.isLoadingLibrary && model.tracks.isEmpty) || (model.isSearching && model.displayedTracks.isEmpty) {
                ProgressView(model.isSearching ? "Searching library…" : "Loading library…")
                    .controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.displayedTracks.isEmpty {
                ContentUnavailableView.search(text: model.search).font(.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    switch model.libraryView {
                    case .home, .artists:
                        ForEach(model.artists) { artist in
                            DisclosureGroup(isExpanded: expansion(artist.id, in: $expandedArtists)) {
                                if expandedArtists.contains(artist.id) {
                                    ForEach(artist.albums) { album in
                                        DisclosureGroup(isExpanded: expansion(album.id, in: $expandedAlbums)) {
                                            if expandedAlbums.contains(album.id) {
                                                ForEach(album.tracks) { TrackLine(track: $0, model: model) }
                                            }
                                        } label: { albumLabel(album) }
                                    }
                                }
                            } label: {
                                HStack { Text(artist.name).lineLimit(1); Spacer(); Text("\(artist.albums.count)").font(.system(size: 10)).foregroundStyle(.tertiary) }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).onTapGesture { model.inspectArtist(artist.name) }
                                    .contextMenu {
                                        LibraryPlaybackActions(model: model, addTitle: "Add Artist to Playlist") { model.albumsForArtist(artist.name).flatMap(\.tracks) }
                                        Button("Shuffle Artist") { model.shuffle(model.albumsForArtist(artist.name).flatMap(\.tracks)) }
                                    }
                            }
                        }
                    case .albums:
                        ForEach(model.visibleAlbums) { album in albumRow(album) }
                    case .years:
                        ForEach(model.yearGroups) { group in
                            DisclosureGroup(isExpanded: expansion(group.id, in: $expandedYears)) {
                                if expandedYears.contains(group.id) {
                                    ForEach(group.albums) { albumRow($0) }
                                }
                            } label: { Text(group.title).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                        }
                    case .folders:
                        FolderLibrary(model: model)
                    case .tags:
                        Section("Genre") {
                            ForEach(model.genreGroups) { group in
                                DisclosureGroup(isExpanded: expansion(group.id, in: $expandedGenres)) {
                                    if expandedGenres.contains(group.id) {
                                        ForEach(group.tracks) { TrackLine(track: $0, model: model, showsArtist: true) }
                                    }
                                } label: { Text(group.title).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                            }
                        }
                        Section("Format") {
                            ForEach(model.formatGroups) { group in
                                DisclosureGroup(isExpanded: expansion(group.id, in: $expandedFormats)) {
                                    if expandedFormats.contains(group.id) {
                                        ForEach(group.tracks) { TrackLine(track: $0, model: model, showsArtist: true) }
                                    }
                                } label: { Text(group.title).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                            }
                        }
                    }
                }.listStyle(.sidebar).environment(\.defaultMinListRowHeight, 25)
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("\(model.albums.count) albums · \(model.tracks.count) tracks").font(.system(size: 10)).foregroundStyle(.secondary)
                HStack { Image(systemName: model.selectedSource?.kind == .local ? "externaldrive" : "network"); Text(model.selectedSource?.kind == .local ? "Scan for Changes" : "Refresh Source"); Spacer() }.font(.system(size: 11)).contentShape(Rectangle()).onTapGesture { model.refresh() }
            }.padding(13)
        }.background(.regularMaterial)
        .onReceive(NotificationCenter.default.publisher(for: .macarokFocusSearch)) { _ in searchFocused = true }
        .onChange(of: model.sourceID) { _, _ in
            expandedArtists = []; expandedAlbums = []; expandedYears = []; expandedGenres = []; expandedFormats = []
        }
    }

    private var shuffleScope: [TrackRecord] { model.libraryView == .folders ? model.folderTracks : model.displayedTracks }

    private func expansion<ID: Hashable>(_ id: ID, in values: Binding<Set<ID>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(id) }, set: { expanded in
            if expanded { values.wrappedValue.insert(id) }
            else { values.wrappedValue.remove(id) }
        })
    }

    private func albumLabel(_ album: AlbumRecord) -> some View {
        HStack { Text(album.title).lineLimit(1); Spacer(); Text(album.year.map(String.init) ?? "").font(.system(size: 10)).foregroundStyle(.tertiary) }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).onTapGesture { model.inspect(album) }
            .contextMenu {
                LibraryPlaybackActions(model: model, addTitle: "Add Album to Playlist") { model.tracksForAlbum(album) }
                Button("Shuffle Album") { model.shuffle(model.tracksForAlbum(album)) }
            }
    }

    private func albumRow(_ album: AlbumRecord) -> some View {
        HStack(spacing: 9) { ArtworkView(track: album.tracks.first, model: model).frame(width: 36, height: 36); VStack(alignment: .leading, spacing: 2) { Text(album.title).lineLimit(1); Text("\(album.artist) · \(album.year.map(String.init) ?? "—")").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) } }.font(.system(size: 12)).padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).onTapGesture(count: 2) { model.add(model.tracksForAlbum(album), play: model.settings.doubleClickPlays) }.onTapGesture { model.inspect(album) }
            .contextMenu {
                LibraryPlaybackActions(model: model, addTitle: "Add Album to Playlist") { model.tracksForAlbum(album) }
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
                    Label(node.name, systemImage: "folder").font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).onTapGesture { model.selectedFolder = node.id; model.contextPage = .folder }
                        .contextMenu { Button("Shuffle Folder") { model.shuffle(model.tracksInFolder(node.id)) }; Button("Add Folder to Playlist") { model.add(model.tracksInFolder(node.id)) } }
                }
            }
            if model.isLoadingLibrary && model.folderNodes.isEmpty {
                ProgressView("Loading folders…").controlSize(.small).font(.caption)
            }
        }
    }
}

extension Notification.Name { static let macarokFocusSearch = Notification.Name("Macarok.focusSearch") }
