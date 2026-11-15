import MacarokCore
import SwiftUI

struct LibraryPane: View {
    @Bindable var model: AppModel
    @State private var expandedArtists: Set<String> = []
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
                Spacer()
                Button { model.shuffle(shuffleScope) } label: { Image(systemName: "shuffle") }.buttonStyle(.borderless).help(model.libraryView == .folders ? "Shuffle selected folder" : "Shuffle this library").disabled(model.tracks.isEmpty)
            }.padding(.horizontal, 15).padding(.bottom, 5)
            if model.sources.isEmpty {
                VStack(spacing: 12) { Image(systemName: "music.note.house").font(.system(size: 28)).foregroundStyle(.tertiary); Text("Bring your music.").foregroundStyle(.secondary); Button("Add Music Folder…", action: model.pickFolder); Button("Connect a Source…") { model.showAddSource = true } }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.displayedTracks.isEmpty {
                ContentUnavailableView.search(text: model.search).font(.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !model.search.isEmpty { ForEach(model.searchResults) { TrackLine(track: $0, model: model, showsArtist: true) } }
                    else {
                        switch model.libraryView {
                        case .home, .artists:
                            ForEach(model.artists) { artist in
                                DisclosureGroup(isExpanded: Binding(get: { expandedArtists.contains(artist.id) }, set: { if $0 { expandedArtists.insert(artist.id) } else { expandedArtists.remove(artist.id) } })) {
                                    ForEach(artist.albums) { album in
                                        DisclosureGroup { ForEach(album.tracks) { TrackLine(track: $0, model: model) } } label: { albumLabel(album) }
                                    }
                                } label: {
                                    HStack { Text(artist.name).lineLimit(1); Spacer(); Text("\(artist.albums.count)").font(.system(size: 10)).foregroundStyle(.tertiary) }.font(.system(size: 12)).contentShape(Rectangle()).onTapGesture { model.inspectArtist(artist.name) }
                                        .contextMenu { Button("Shuffle Artist") { model.shuffle(artist.albums.flatMap(\.tracks)) }; Button("Add Artist to Playlist") { model.add(artist.albums.flatMap(\.tracks)) } }
                                }
                            }
                        case .albums:
                            ForEach(model.visibleAlbums) { album in albumRow(album) }
                        case .years:
                            ForEach(years, id: \.self) { year in
                                DisclosureGroup(year == 0 ? "Unknown Year" : String(year)) { ForEach(model.albums.filter { ($0.year ?? 0) == year }) { albumRow($0) } }
                            }
                        case .folders:
                            FolderLibrary(model: model)
                        case .tags:
                            Section("Genre") {
                                ForEach(genres, id: \.self) { genre in DisclosureGroup(genre) { ForEach(model.tracks.filter { ($0.genre ?? "Unknown") == genre }) { TrackLine(track: $0, model: model, showsArtist: true) } } }
                            }
                            Section("Format") {
                                ForEach(formats, id: \.self) { format in DisclosureGroup(format) { ForEach(model.tracks.filter { $0.format == format }) { TrackLine(track: $0, model: model, showsArtist: true) } } }
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
        .onChange(of: model.sourceID) { _, _ in expandedArtists = [] }
    }

    private var years: [Int] { Array(Set(model.tracks.map { $0.year ?? 0 })).sorted(by: >) }
    private var genres: [String] { Array(Set(model.tracks.map { ($0.genre?.isEmpty == false ? $0.genre : nil) ?? "Unknown" })).sorted() }
    private var formats: [String] { Array(Set(model.tracks.map(\.format))).sorted() }
    private var shuffleScope: [TrackRecord] { model.libraryView == .folders ? model.folderTracks : model.displayedTracks }

    private func albumLabel(_ album: AlbumRecord) -> some View {
        HStack { Text(album.title).lineLimit(1); Spacer(); Text(album.year.map(String.init) ?? "").font(.system(size: 10)).foregroundStyle(.tertiary) }.font(.system(size: 11)).contentShape(Rectangle()).onTapGesture { model.inspect(album) }
            .contextMenu { Button("Add Album to Playlist") { model.add(album.tracks) }; Button("Shuffle Album") { model.shuffle(album.tracks) } }
    }

    private func albumRow(_ album: AlbumRecord) -> some View {
        HStack(spacing: 9) { ArtworkView(track: album.tracks.first, model: model).frame(width: 36, height: 36); VStack(alignment: .leading, spacing: 2) { Text(album.title).lineLimit(1); Text("\(album.artist) · \(album.year.map(String.init) ?? "—")").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) } }.font(.system(size: 12)).padding(.vertical, 3).contentShape(Rectangle()).onTapGesture(count: 2) { model.add(album.tracks, play: model.settings.doubleClickPlays) }.onTapGesture { model.inspect(album) }
            .contextMenu { Button("Add Album to Playlist") { model.add(album.tracks) }; Button("Shuffle Album") { model.shuffle(album.tracks) } }
    }
}

struct FolderLibrary: View {
    @Bindable var model: AppModel
    @State private var nodes: [FolderNode] = []
    @State private var loadedSourceID: String?
    @State private var isLoading = false

    var body: some View {
        Section {
            if loadedSourceID == model.sourceID, !nodes.isEmpty {
                OutlineGroup(nodes, children: \.children) { node in
                    Label(node.name, systemImage: "folder").font(.system(size: 12)).contentShape(Rectangle()).onTapGesture { model.selectedFolder = node.id; model.contextPage = .folder }
                        .contextMenu { Button("Shuffle Folder") { model.shuffle(model.tracksInFolder(node.id)) }; Button("Add Folder to Playlist") { model.add(model.tracksInFolder(node.id)) } }
                }
            }
            if isLoading || loadedSourceID != model.sourceID {
                ProgressView("Loading folders…").controlSize(.small).font(.caption)
            }
        }
        .task(id: FolderSnapshotID(sourceID: model.sourceID, revision: model.libraryRevision)) {
            let sourceID = model.sourceID
            let revision = model.libraryRevision
            let tracks = model.tracks
            let sources = model.selectedSource.map { [$0] } ?? []
            let rootName = model.selectedSource?.name ?? "Music"
            isLoading = true
            let task = Task.detached(priority: .userInitiated) {
                try LibraryFolderIndex.build(tracks: tracks, sources: sources, rootName: rootName)
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: { task.cancel() }
                guard !Task.isCancelled, model.sourceID == sourceID, model.libraryRevision == revision else { return }
                nodes = result
                loadedSourceID = sourceID
                isLoading = false
            } catch {
                guard !Task.isCancelled, model.sourceID == sourceID, model.libraryRevision == revision else { return }
                isLoading = false
            }
        }
    }
}

private struct FolderSnapshotID: Hashable {
    let sourceID: String?
    let revision: Int
}

extension Notification.Name { static let macarokFocusSearch = Notification.Name("Macarok.focusSearch") }
