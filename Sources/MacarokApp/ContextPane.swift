import MacarokCore
import SwiftUI

struct ContextPane: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            CenterPanelHeader(model: model)
            if model.centerPage == .home { homeContent }
            else { playingContent }
        }
    }

    var showsRadioContext: Bool {
        model.isRadioTrack(model.playingContextTrack) && (model.contextPage == .track || model.contextPage == .home)
    }

    @ViewBuilder private var homeContent: some View {
        if model.sources.isEmpty { WelcomeView(model: model) }
        else if model.isRadioSource {
            ContentUnavailableView("Internet Radio", systemImage: "antenna.radiowaves.left.and.right", description: Text("Choose a station from your library, or browse the directory to find one."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let id = model.focusedPodcastShowID, let source = model.sourcesByID[id] {
            ScrollView { PodcastShowHome(model: model, source: source).padding(22).frame(maxWidth: .infinity, alignment: .leading) }
                .background(Color(nsColor: .textBackgroundColor))
        } else if model.tracks.isEmpty && !model.showsPodcastHome && (model.homeFilter != .all || !model.isAllSources || !model.radioStations.contains(where: \.isFavorite)) {
            HomeView(model: model).padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        } else {
            ScrollView { HomeView(model: model).padding(22).frame(maxWidth: .infinity, alignment: .leading) }
                .background(Color(nsColor: .textBackgroundColor))
        }
    }

    @ViewBuilder private var playingContent: some View {
        switch model.displayedContextMode {
        case .lyrics: LyricsPane(model: model)
        case .wikipedia: WikipediaPane(model: model)
        case .editAlbumMetadata:
            if let session = model.albumMetadataEditingSession {
                AlbumMetadataEditor(model: model, session: session, onFinish: { model.finishAlbumMetadataEditing(sessionID: session.id) })
            } else {
                ContentUnavailableView("Choose an Album", systemImage: "square.stack", description: Text("Play or select a song to edit its album metadata."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .editMetadata:
            if let session = model.metadataEditingSession {
                InlineMetadataEditor(model: model, session: session, onFinish: { model.finishMetadataEditing(sessionID: session.id) })
            } else if model.isRadioTrack(model.playingContextTrack) {
                ContentUnavailableView("Metadata Unavailable", systemImage: "antenna.radiowaves.left.and.right", description: Text("Live radio streams do not have editable music tags."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Choose a Track", systemImage: "music.note", description: Text("Play or select a track to edit its metadata."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .context:
            if showsRadioContext { RadioNowPlayingView(model: model, track: model.playingContextTrack) }
            else if (model.contextPage == .track || model.contextPage == .home) && model.playingContextTrack == nil {
                ContentUnavailableView("Choose a Track", systemImage: "music.note", description: Text("Play or select a track to see its context."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch model.contextPage {
                        case .home, .track:
                            if let track = model.playingContextTrack { TrackContextView(model: model, track: track) }
                            else { ContentUnavailableView("Choose a Track", systemImage: "music.note", description: Text("Play or select a track to see its context.")) }
                        case .album:
                            if let album = model.selectedAlbum { AlbumContextView(model: model, album: album) }
                            else { ContentUnavailableView("Choose an Album", systemImage: "square.stack") }
                        case .artist: ArtistContextView(model: model)
                        case .folder: FolderContextView(model: model)
                        }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
}

struct WelcomeView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.house").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(.secondary)
            Text("Welcome to Macarok").font(.system(size: 27, weight: .semibold))
            Text("Your library, your listening context, your playlist.\nAll in one place.").multilineTextAlignment(.center).foregroundStyle(.secondary).font(.system(size: 13))
            Button(action: model.pickFolder) { Label("Add Music Folder…", systemImage: "folder.badge.plus") }.buttonStyle(.borderedProminent).controlSize(.large)
            Button("Explore Music Sources…") { model.presentAddSource(from: .mainWindow) }.buttonStyle(.link)
            Text("MP3 · FLAC · Ogg Vorbis · Opus · CUE").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 14)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(25)
    }
}

struct HomeView: View {
    @Bindable var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 170), spacing: 14, alignment: .top)]

    private var isEmpty: Bool { model.tracks.isEmpty && !model.showsPodcastHome }

    var body: some View {
        VStack(alignment: isEmpty ? .center : .leading, spacing: 23) {
            VStack(alignment: isEmpty ? .center : .leading, spacing: 5) {
                Text(model.scopeTitle.uppercased()).font(.system(size: 10, weight: .medium)).tracking(1).foregroundStyle(.secondary)
                Text(model.homeFilter == .all ? "Your Library" : model.homeFilter.title).font(.system(size: 27, weight: .semibold))
                Text(model.homeLibrarySummary).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: isEmpty ? .center : .leading)
            .multilineTextAlignment(isEmpty ? .center : .leading)
            if isEmpty && (model.homeFilter != .all || !model.isAllSources || !model.radioStations.contains(where: \.isFavorite)) {
                Spacer(minLength: 0)
                VStack(spacing: 16) {
                    Image(systemName: "music.note").font(.system(size: 42)).foregroundStyle(.tertiary)
                    VStack(spacing: 8) {
                        Text("Ready to discover your music").font(.title3.weight(.semibold))
                        Text(model.isRefreshing || model.isLoadingLibrary ? "Your library is loading." : "Refresh this source to load its music.")
                            .foregroundStyle(.secondary)
                    }.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    if model.isRefreshing || model.isLoadingLibrary {
                        ProgressView(model.isRefreshing ? model.refreshProgress : "Loading library…").controlSize(.small)
                            .font(.caption).foregroundStyle(.secondary)
                    } else { Button("Refresh Source", action: model.refresh) }
                }.frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                if !model.tracks.isEmpty {
                    if model.homeFilter == .all || model.homeFilter == .recentlyAdded {
                        VStack(alignment: .leading, spacing: 11) {
                            if model.homeFilter == .all { Text("Recently Added").font(.system(size: 14, weight: .semibold)) }
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                                ForEach(model.recentlyAdded, id: \.presentationID) { AlbumTile(model: model, album: $0) }
                            }
                        }
                    }
                    if model.homeFilter == .all || model.homeFilter == .recentlyPlayed {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.homeFilter == .all { Text("Recently Played").font(.system(size: 14, weight: .semibold)) }
                            if model.recentlyPlayed.isEmpty { emptyHistory }
                            else { ForEach(model.recentlyPlayed.prefix(model.homeFilter == .all ? 5 : 8)) { track in historyRow(track) } }
                        }
                    }
                    if model.homeFilter == .all || model.homeFilter == .mostPlayed {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.homeFilter == .all { Text("Most Played").font(.system(size: 14, weight: .semibold)) }
                            if model.mostPlayedTracks.isEmpty { emptyHistory }
                            else { mostPlayedRows }
                        }
                    }
                }
                if model.isAllSources && model.homeFilter == .all {
                    PodcastHomeSection(model: model)
                    RadioFavoritesSection(model: model)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: isEmpty ? .infinity : nil)
    }
    private var emptyHistory: some View { Text("Start listening to build your listening history.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 5) }
    private func historyRow(_ track: TrackRecord, showsCount: Bool = false) -> some View {
        HStack(spacing: 10) {
            ArtworkView(track: track, model: model).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) { Text(track.title).lineLimit(1); Text(track.artist).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            SourceBadge(model: model, sourceID: track.sourceID)
            Spacer()
            if showsCount { Text("\(track.playCount) plays").font(.system(size: 10)).foregroundStyle(.secondary) }
            else if let date = track.lastPlayedAt {
                Text("Last Played: \(Self.historyDate.string(from: date))")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }.font(.system(size: 12)).padding(.vertical, 3).contentShape(Rectangle()).onLibraryClick(inspect: { model.inspect(track) }, add: { model.doubleClick(track) })
            .contextMenu { LibraryPlaybackActions(model: model, addTitle: "Add to Active Playlist") { [track] }; TrackFileActions(model: model, track: track) }
    }

    private static let historyDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "MMM d, yyyy 'at' HH:mm"
        return formatter
    }()

    private var mostPlayedRows: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Tracks").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(model.mostPlayedTracks.prefix(8)) { track in
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkView(track: track, model: model).frame(width: 140, height: 140)
                            Text(track.title).font(.system(size: 11, weight: .medium)).lineLimit(2).frame(height: 28, alignment: .topLeading)
                            Text(track.artist).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).frame(height: 13, alignment: .topLeading)
                            SourceBadge(model: model, sourceID: track.sourceID)
                            playCount(track.playCount)
                        }.frame(width: 140, alignment: .topLeading).contentShape(Rectangle())
                            .onLibraryClick(inspect: { model.inspect(track) }, add: { model.doubleClick(track) })
                            .contextMenu { LibraryPlaybackActions(model: model) { [track] } }
                    }
                }
            }.scrollIndicators(.hidden)
            Text("Artists").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(model.mostPlayedArtists.prefix(8)) { artist in
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: "person.crop.circle").resizable().scaledToFit().padding(30)
                                .frame(width: 140, height: 140).foregroundStyle(.tertiary)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            Text(artist.name).font(.system(size: 11, weight: .medium)).lineLimit(2).frame(height: 28, alignment: .topLeading)
                            SourceGroupBadge(model: model, sourceIDs: artist.sourceIDs)
                            playCount(artist.playCount)
                        }.frame(width: 140, alignment: .topLeading).contentShape(Rectangle())
                            .onLibraryClick(inspect: { model.inspectArtist(artist.name) }, add: { model.doubleClickSelection(model.albumsForArtist(artist.name).flatMap(\.tracks)) })
                            .contextMenu { LibraryPlaybackActions(model: model, addTitle: "Add Artist to Playlist") { model.albumsForArtist(artist.name).flatMap(\.tracks) } }
                    }
                }
            }.scrollIndicators(.hidden)
            Text("Albums").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(model.mostPlayedAlbums.prefix(8), id: \.presentationID) { album in
                        VStack(alignment: .leading, spacing: 5) {
                            AlbumTile(model: model, album: album)
                            playCount(album.playCount)
                        }.frame(width: 140, alignment: .topLeading)
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }

    private func playCount(_ count: Int) -> some View {
        Text("\(count) plays").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
    }
}

struct AlbumTile: View {
    @Bindable var model: AppModel
    let album: AlbumRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(track: album.tracks.first, model: model).aspectRatio(1, contentMode: .fit)
            Text(album.title).font(.system(size: 11, weight: .medium)).lineLimit(2).frame(height: 28, alignment: .topLeading)
            Text(album.artist).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).frame(height: 13, alignment: .topLeading)
            SourceBadge(model: model, sourceID: album.sourceID)
        }.frame(maxWidth: .infinity, alignment: .topLeading).contentShape(Rectangle()).onLibraryClick(inspect: { model.inspect(album) }, add: { model.doubleClickSelection(model.tracksForAlbum(album)) })
            .contextMenu {
                LibraryPlaybackActions(model: model, addTitle: "Add Album to Playlist") { model.tracksForAlbum(album) }; AlbumMetadataAction(model: model, album: album)
                Button("Shuffle Album") { model.shuffle(album.tracks) }
                Button("Choose Artwork…") { model.beginArtworkEditing(album.tracks.first) }
            }
    }
}

struct TrackContextView: View {
    @Bindable var model: AppModel
    let track: TrackRecord
    var body: some View {
        VStack(alignment: .leading, spacing: ContextLayout.sectionSpacing) {
            ContextHeader(eyebrow: model.currentTrack?.id == track.id ? "Now Playing" : isPodcast ? "Selected Episode" : "Selected Track") {
                ArtworkView(track: track, model: model)
            } details: {
                    Text(track.title).font(ContextLayout.titleFont).textSelection(.enabled)
                        .contextMenu { LibraryPlaybackActions(model: model, addTitle: "Add to Active Playlist") { [track] }; TrackFileActions(model: model, track: track) }
                    if isPodcast {
                        Text(track.artist).font(.system(size: 13)).foregroundStyle(.secondary)
                        Button(track.album) { model.openPodcastShow(track.sourceID) }.buttonStyle(.link).font(.system(size: 12))
                            .help("Open this show")
                    } else {
                    Button(track.artist) { model.inspectArtist(track.albumArtist) }.buttonStyle(.link).font(.system(size: 13))
                        .contextMenu {
                            if model.scopeIncludes(sourceID: track.sourceID) {
                                LibraryPlaybackActions(model: model, addTitle: "Add Artist to Playlist") { model.albumsForArtist(track.albumArtist).flatMap(\.tracks) }
                            }
                        }
                    Button(track.album) { model.inspectAlbum(containing: track) }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
                        .contextMenu {
                            if model.scopeIncludes(sourceID: track.sourceID), let album = model.albumsForArtist(track.albumArtist).first(where: { $0.id == track.albumID && $0.sourceID == track.sourceID }) {
                                LibraryPlaybackActions(model: model, addTitle: "Add Album to Playlist") { model.tracksForAlbum(album) }; AlbumMetadataAction(model: model, album: album)
                            }
                        }
                    }
                    Text([track.year.map(String.init), track.genre].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text((track.isCUETrack ? "CUE + " : "") + track.format.uppercased()).font(.system(size: 9, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 2).overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary))
            }
            ContextPlaybackBar(model: model, allowsShuffle: false) { [track] } trailing: {
                if !isPodcast { Button { model.beginArtworkEditing(track) } label: { Image(systemName: "photo") }.help("Choose artwork") }
            }
            Divider()
            Picker("Track details", selection: Binding(get: { model.contextTab }, set: model.selectContextTab)) { Text("Overview").tag("Overview"); Text("Tags").tag("Tags") }
                .pickerStyle(.segmented).labelsHidden().frame(width: 185).frame(maxWidth: .infinity)
            PodcastEpisodeActions(model: model, track: track)
            if model.contextTab == "Overview" { overview }
            else { tags }
            Divider()
            HStack { Label(model.sources.first { $0.id == track.sourceID }?.name ?? "Unavailable source", systemImage: track.url?.isFileURL == true ? "externaldrive" : "network"); Spacer() }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                fact("Played", "\(track.playCount) times")
                Spacer()
                VStack(alignment: .leading, spacing: 4) { Text("Last played").font(.system(size: 10)).foregroundStyle(.secondary); if let date = track.lastPlayedAt { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)) } else { Text("Never").font(.system(size: 12)) } }
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rating").font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack(spacing: 1) { ForEach(1...5, id: \.self) { star in Button { model.rate(track, value: star == track.rating ? 0 : star) } label: { Image(systemName: star <= track.rating ? "star.fill" : "star").font(.system(size: 11)) }.buttonStyle(.plain).help("Rate \(star) stars") } }
                }
            }
            Divider()
            if isPodcast {
                PodcastChaptersView(model: model, timeline: model.player.timeline, track: track)
                PodcastEpisodeNotesView(model: model, track: track)
            }
            else {
            HStack { Text("About this recording").font(.system(size: 13, weight: .semibold)); Spacer(); Button { model.beginMetadataEditing(track) } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.borderless).help("Edit song metadata") }
            Text("\(track.title) by \(track.artist), from \(track.album).\(track.isCUETrack ? " This track is a region of a shared audio file." : "")").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            }
            let related = Array(model.albumsForArtist(track.albumArtist).lazy.filter { $0.id != track.albumID || $0.sourceID != track.sourceID }.prefix(4))
            if !related.isEmpty {
                Text("More in your collection").font(.system(size: 13, weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 150), alignment: .top)], alignment: .leading, spacing: 12) { ForEach(related, id: \.presentationID) { AlbumTile(model: model, album: $0) } }
            }
        }
    }
    private var isPodcast: Bool { model.isPodcastTrack(track) }
    private func fact(_ label: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 4) { Text(label).font(.system(size: 10)).foregroundStyle(.secondary); Text(value).font(.system(size: 12)) } }
    private var tags: some View {
        VStack(alignment: .leading, spacing: 13) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 9) {
                tag("Title", track.title); tag("Artist", track.artist); tag("Album artist", track.albumArtist); tag("Album", track.album)
                tag("Year", track.year.map(String.init) ?? "—"); tag("Genre", track.genre ?? "—")
                tag("Track", track.trackNumber.map(String.init) ?? "—"); tag("Disc", track.discNumber.map(String.init) ?? "—")
                tag("Format", track.format); tag("Duration", track.formattedDuration)
                if let url = track.url { tag("File", url.lastPathComponent) }
                if let cue = track.cuePath { tag("CUE sheet", URL(fileURLWithPath: cue).lastPathComponent) }
                if let start = track.startTime { tag("Segment", "\(start.playbackTime) – \((track.endTime ?? start + track.duration).playbackTime)") }
                if let path = track.remotePath { tag("Server path", path) }
                if track.metadataLocked { tag("Metadata", "Personal corrections preserved") }
            }.font(.system(size: 12)).textSelection(.enabled)
            if !isPodcast {
                HStack { Button { model.beginMetadataEditing(track) } label: { Label("Edit Song Metadata…", systemImage: "square.and.pencil") }; Button { model.beginArtworkEditing(track) } label: { Label("Artwork…", systemImage: "photo") } }.controlSize(.small)
            }
        }
    }
    private func tag(_ label: String, _ value: String) -> some View { GridRow(alignment: .top) { Text(label).foregroundStyle(.secondary); Text(value).frame(maxWidth: .infinity, alignment: .leading) } }
}

struct AlbumContextView: View {
    @Bindable var model: AppModel
    let album: AlbumRecord
    var body: some View {
        VStack(alignment: .leading, spacing: ContextLayout.sectionSpacing) {
            ContextHeader(eyebrow: "Album · \(album.year.map(String.init) ?? "Unknown Year")") {
                ArtworkView(track: album.tracks.first, model: model)
            } details: {
                    Text(album.title).font(ContextLayout.titleFont)
                        .contextMenu { LibraryPlaybackActions(model: model, addTitle: "Add Album to Playlist") { model.tracksForAlbum(album) }; AlbumMetadataAction(model: model, album: album) }
                    Button(album.artist) { model.inspectArtist(album.artist) }.buttonStyle(.link).font(.system(size: 13))
                        .contextMenu {
                            LibraryPlaybackActions(model: model, addTitle: "Add Artist to Playlist") {
                                model.albumsForArtist(album.artist).flatMap(\.tracks)
                            }
                        }
                    Text("\(pluralized(album.tracks.count, "track")) · \(album.duration.playbackTime)").font(.system(size: 11)).foregroundStyle(.secondary)
                    SourceBadge(model: model, sourceID: album.sourceID)
            }
            ContextPlaybackBar(model: model) { album.tracks } trailing: {
                Button { model.beginArtworkEditing(album.tracks.first) } label: { Image(systemName: "photo") }.help("Choose album artwork")
            }
            Divider()
            LazyVStack(spacing: 0) { ForEach(album.tracks) { track in TrackLine(track: track, model: model).padding(.horizontal, 5).padding(.vertical, 5); Divider().opacity(0.45) } }
            if album.tracks.contains(where: \.isCUETrack) { Label("CUE tracks reference their original audio file. Each track has its own playback boundaries.", systemImage: "waveform.path").font(.system(size: 11)).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 6)) }
        }
    }
}

struct ArtistContextView: View {
    @Bindable var model: AppModel
    var body: some View {
        let name = model.selectedArtist ?? model.selectedTrack?.albumArtist ?? "Choose an Artist"
        let albums = model.albumsForArtist(name)
        let artist = model.artistSummary(named: name)
        VStack(alignment: .leading, spacing: ContextLayout.sectionSpacing) {
            ContextHeader(eyebrow: "Artist") {
                ArtistArtworkView(model: model, name: name)
            } details: {
                Text(name).font(ContextLayout.titleFont)
                    .contextMenu { LibraryPlaybackActions(model: model, addTitle: "Add Artist to Playlist") { model.albumsForArtist(name).flatMap(\.tracks) } }
                Text("\(pluralized(albums.count, "album")) · \(pluralized(artist?.trackCount ?? 0, "track"))").font(.system(size: 11)).foregroundStyle(.secondary)
                if let artist { SourceGroupBadge(model: model, sourceIDs: artist.sourceIDs) }
            }
            ContextPlaybackBar(model: model) { albums.flatMap(\.tracks) }
            Divider()
            Text("Albums").font(.system(size: 14, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 15, alignment: .top)], alignment: .leading, spacing: 20) { ForEach(albums, id: \.presentationID) { AlbumTile(model: model, album: $0) } }
        }
    }
}

struct FolderContextView: View {
    @Bindable var model: AppModel
    var body: some View {
        let tracks = model.folderTracks
        VStack(alignment: .leading, spacing: ContextLayout.sectionSpacing) {
            ContextHeader(eyebrow: "Folder") {
                ContextSymbolArtwork(systemImage: "folder")
            } details: {
                Text(model.folderTitle).font(ContextLayout.titleFont)
                Text("\(pluralized(tracks.count, "track")), including subfolders").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ContextPlaybackBar(model: model) { tracks }
            Divider()
            LazyVStack(spacing: 0) { ForEach(tracks) { TrackLine(track: $0, model: model, showsArtist: true).padding(.vertical, 4); Divider().opacity(0.4) } }
        }
    }
}
