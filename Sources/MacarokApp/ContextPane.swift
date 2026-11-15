import MacarokCore
import SwiftUI

struct ContextPane: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(pageTitle).fontWeight(.semibold)
                Spacer()
                if model.contextPage != .home { Button { model.contextPage = .home; model.libraryView = .home } label: { Image(systemName: "house") }.help("Home") }
                Button(action: model.showCurrentTrack) { Image(systemName: "waveform") }.help("Show current track").disabled(model.currentTrack == nil)
                Button { if let track = model.selectedTrack { model.editingTrack = track } } label: { Image(systemName: "square.and.pencil") }.help("Edit metadata").disabled(model.selectedTrack == nil)
            }.font(.system(size: 12)).buttonStyle(.borderless).padding(.horizontal, 16).frame(height: 42).background(.bar)
            Divider()
            if model.sources.isEmpty { WelcomeView(model: model) }
            else if model.contextPage == .home && model.tracks.isEmpty {
                HomeView(model: model).padding(22).background(Color(nsColor: .textBackgroundColor))
            }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch model.contextPage {
                        case .home: HomeView(model: model)
                        case .track:
                            if let track = model.selectedTrack { TrackContextView(model: model, track: track) }
                            else { ContentUnavailableView("Choose a Track", systemImage: "music.note", description: Text("Select a track in your library or active playlist.")) }
                        case .album:
                            if let album = model.selectedAlbum { AlbumContextView(model: model, album: album) }
                            else { ContentUnavailableView("Choose an Album", systemImage: "square.stack") }
                        case .artist: ArtistContextView(model: model)
                        case .folder: FolderContextView(model: model)
                        }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }.background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
    private var pageTitle: String {
        switch model.contextPage { case .home: "Home"; case .track: "Listening Context"; case .album: "Album"; case .artist: "Artist"; case .folder: "Folder" }
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
            Button("Connect OpenSubsonic or Add a Podcast…") { model.showAddSource = true }.buttonStyle(.link)
            Text("MP3 · FLAC · Ogg Vorbis · Opus · CUE").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 14)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(25)
    }
}

struct HomeView: View {
    @Bindable var model: AppModel
    @State private var mostPlayed = "Albums"
    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 170), spacing: 14, alignment: .top)]

    var body: some View {
        VStack(alignment: model.tracks.isEmpty ? .center : .leading, spacing: 23) {
            VStack(alignment: model.tracks.isEmpty ? .center : .leading, spacing: 5) {
                Text(model.selectedSource?.name.uppercased() ?? "YOUR LIBRARY").font(.system(size: 10, weight: .medium)).tracking(1).foregroundStyle(.secondary)
                Text("Your Library").font(.system(size: 27, weight: .semibold))
                Text("\(model.albums.count) albums · \(model.tracks.count) tracks").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: model.tracks.isEmpty ? .center : .leading)
            .multilineTextAlignment(model.tracks.isEmpty ? .center : .leading)
            if model.tracks.isEmpty {
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
                VStack(alignment: .leading, spacing: 11) {
                    Text("Recently Added").font(.system(size: 14, weight: .semibold))
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) { ForEach(model.recentlyAdded) { AlbumTile(model: model, album: $0) } }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recently Played").font(.system(size: 14, weight: .semibold))
                    if model.recentlyPlayed.isEmpty { emptyHistory }
                    else { ForEach(model.recentlyPlayed.prefix(5)) { track in historyRow(track) } }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Most Played").font(.system(size: 14, weight: .semibold)); Spacer(); Picker("Show", selection: $mostPlayed) { Text("Albums").tag("Albums"); Text("Tracks").tag("Tracks"); Text("Artists").tag("Artists") }.labelsHidden().fixedSize().controlSize(.small) }
                    if model.mostPlayedTracks.isEmpty { emptyHistory }
                    else if mostPlayed == "Albums" {
                        ForEach(model.mostPlayedAlbums.prefix(5)) { album in Button { model.inspect(album) } label: { HStack { ArtworkView(track: album.tracks.first, model: model).frame(width: 36, height: 36); VStack(alignment: .leading, spacing: 2) { Text(album.title).lineLimit(1); Text(album.artist).font(.system(size: 10)).foregroundStyle(.secondary) }; Spacer(); Text("\(album.playCount) plays").font(.system(size: 10)).foregroundStyle(.secondary) }.font(.system(size: 12)) }.buttonStyle(.plain) }
                    } else if mostPlayed == "Artists" {
                        ForEach(model.mostPlayedArtists.prefix(5)) { artist in Button { model.inspectArtist(artist.name) } label: { HStack { Image(systemName: "person.crop.circle").font(.system(size: 26)).foregroundStyle(.tertiary); Text(artist.name); Spacer(); Text("\(artist.playCount) plays").font(.system(size: 10)).foregroundStyle(.secondary) }.font(.system(size: 12)) }.buttonStyle(.plain) }
                    } else { ForEach(model.mostPlayedTracks.prefix(5)) { historyRow($0, showsCount: true) } }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: model.tracks.isEmpty ? .infinity : nil)
    }
    private var emptyHistory: some View { Text("Start listening to build your listening history.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 5) }
    private func historyRow(_ track: TrackRecord, showsCount: Bool = false) -> some View {
        HStack(spacing: 10) {
            ArtworkView(track: track, model: model).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) { Text(track.title).lineLimit(1); Text(track.artist).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            if showsCount { Text("\(track.playCount) plays").font(.system(size: 10)).foregroundStyle(.secondary) }
            else if let date = track.lastPlayedAt { Text(date, style: .relative).font(.system(size: 10)).foregroundStyle(.secondary) }
        }.font(.system(size: 12)).padding(.vertical, 3).contentShape(Rectangle()).onLibraryClick(inspect: { model.inspect(track) }, add: { model.doubleClick(track) })
    }
}

struct AlbumTile: View {
    @Bindable var model: AppModel
    let album: AlbumRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(track: album.tracks.first, model: model).aspectRatio(1, contentMode: .fit)
            Text(album.title).font(.system(size: 11, weight: .medium)).lineLimit(2)
            Text(album.artist).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }.contentShape(Rectangle()).onLibraryClick(inspect: { model.inspect(album) }, add: { model.add(album.tracks, play: model.settings.doubleClickPlays) })
            .contextMenu { Button("Add Album to Playlist") { model.add(album.tracks) }; Button("Shuffle Album") { model.shuffle(album.tracks) }; Button("Choose Artwork…") { model.artworkTrack = album.tracks.first } }
    }
}

struct TrackContextView: View {
    @Bindable var model: AppModel
    let track: TrackRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.currentTrack?.id == track.id ? "NOW PLAYING" : "SELECTED TRACK").font(.system(size: 10, weight: .medium)).tracking(1).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 17) {
                ArtworkView(track: track, model: model).frame(width: 126, height: 126)
                VStack(alignment: .leading, spacing: 6) {
                    Text(track.title).font(.system(size: 22, weight: .semibold)).textSelection(.enabled)
                    Button(track.artist) { model.inspectArtist(track.albumArtist) }.buttonStyle(.link).font(.system(size: 13))
                    Button(track.album) { model.selectedAlbumID = track.albumID; model.contextPage = .album }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
                    Text([track.year.map(String.init), track.genre].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text((track.isCUETrack ? "CUE + " : "") + track.format.uppercased()).font(.system(size: 9, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 2).overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary))
                }
            }
            Picker("Context", selection: $model.contextTab) { Text("Overview").tag("Overview"); Text("Lyrics").tag("Lyrics"); Text("Tags").tag("Tags") }.pickerStyle(.segmented)
                .onChange(of: model.contextTab) { _, value in if value == "Lyrics" { model.loadLyrics() } }
            if model.contextTab == "Overview" { overview }
            else if model.contextTab == "Lyrics" {
                if model.isLoadingLyrics { ProgressView("Loading lyrics…").padding() }
                else if let lyrics = model.lyrics, !lyrics.isEmpty { Text(lyrics).font(.system(size: 14)).lineSpacing(7).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                else { ContentUnavailableView("No Lyrics Attached", systemImage: "text.quote", description: Text("Embedded lyrics, local LRC files, and lyrics provided by the server appear here.")) }
            } else { tags }
            Divider()
            HStack { Label(model.sources.first { $0.id == track.sourceID }?.name ?? "Unavailable source", systemImage: track.url?.isFileURL == true ? "externaldrive" : "network"); Spacer(); Button("Add to Playlist") { model.add([track]) } }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                fact("Played", "\(track.playCount) times")
                Spacer()
                VStack(alignment: .leading, spacing: 4) { Text("Last played").font(.system(size: 10)).foregroundStyle(.secondary); if let date = track.lastPlayedAt { Text(date, style: .relative).font(.system(size: 12)) } else { Text("Never").font(.system(size: 12)) } }
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rating").font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack(spacing: 1) { ForEach(1...5, id: \.self) { star in Button { model.rate(track, value: star == track.rating ? 0 : star) } label: { Image(systemName: star <= track.rating ? "star.fill" : "star").font(.system(size: 11)) }.buttonStyle(.plain).help("Rate \(star) stars") } }
                }
            }
            Divider()
            HStack { Text("About this recording").font(.system(size: 13, weight: .semibold)); Spacer(); Button { model.editingTrack = track } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.borderless).help("Edit metadata") }
            Text("\(track.title) by \(track.artist), from \(track.album).\(track.isCUETrack ? " This track is a region of a shared audio file." : "")").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            let related = Array(model.albumsForArtist(track.albumArtist).lazy.filter { $0.id != track.albumID }.prefix(4))
            if !related.isEmpty {
                Text("More in your collection").font(.system(size: 13, weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 150))], alignment: .leading, spacing: 12) { ForEach(related) { AlbumTile(model: model, album: $0) } }
            }
        }
    }
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
            HStack { Button { model.editingTrack = track } label: { Label("Edit Metadata…", systemImage: "square.and.pencil") }; Button { model.artworkTrack = track } label: { Label("Artwork…", systemImage: "photo") } }.controlSize(.small)
        }
    }
    private func tag(_ label: String, _ value: String) -> some View { GridRow(alignment: .top) { Text(label).foregroundStyle(.secondary); Text(value).frame(maxWidth: .infinity, alignment: .leading) } }
}

struct AlbumContextView: View {
    @Bindable var model: AppModel
    let album: AlbumRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("ALBUM · \(album.year.map(String.init) ?? "UNKNOWN YEAR")").font(.system(size: 10)).tracking(1).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                ArtworkView(track: album.tracks.first, model: model).frame(width: 118, height: 118)
                VStack(alignment: .leading, spacing: 7) { Text(album.title).font(.system(size: 23, weight: .semibold)); Button(album.artist) { model.inspectArtist(album.artist) }.buttonStyle(.link); Text("\(album.tracks.count) tracks · \(album.duration.playbackTime)").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            HStack { Button { model.add(album.tracks) } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }.buttonStyle(.borderedProminent); Button { model.shuffle(album.tracks) } label: { Label("Shuffle", systemImage: "shuffle") }; Spacer(); Button { model.artworkTrack = album.tracks.first } label: { Image(systemName: "photo") }.help("Choose album artwork") }.controlSize(.small)
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
        VStack(alignment: .leading, spacing: 18) {
            Text("ARTIST").font(.system(size: 10)).tracking(1).foregroundStyle(.secondary)
            Text(name).font(.system(size: 29, weight: .semibold))
            Text("\(albums.count) albums · \(artist?.trackCount ?? 0) tracks in this source").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack { Button { model.shuffle(albums.flatMap(\.tracks)) } label: { Label("Shuffle Artist", systemImage: "shuffle") }.buttonStyle(.borderedProminent); Button("Add to Playlist") { model.add(albums.flatMap(\.tracks)) } }.controlSize(.small)
            Divider()
            Text("Albums").font(.system(size: 14, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 15)], alignment: .leading, spacing: 20) { ForEach(albums) { AlbumTile(model: model, album: $0) } }
        }
    }
}

struct FolderContextView: View {
    @Bindable var model: AppModel
    var body: some View {
        let tracks = model.folderTracks
        VStack(alignment: .leading, spacing: 16) {
            Text("FOLDER").font(.system(size: 10)).tracking(1).foregroundStyle(.secondary)
            Text((model.selectedFolder ?? "").isEmpty ? model.selectedSource?.name ?? "Music" : URL(fileURLWithPath: model.selectedFolder ?? "").lastPathComponent).font(.system(size: 25, weight: .semibold))
            Text("\(tracks.count) tracks, including subfolders").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack { Button { model.add(tracks) } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }.buttonStyle(.borderedProminent); Button { model.shuffle(tracks) } label: { Label("Shuffle Folder", systemImage: "shuffle") } }.controlSize(.small)
            Divider()
            LazyVStack(spacing: 0) { ForEach(tracks) { TrackLine(track: $0, model: model, showsArtist: true).padding(.vertical, 4); Divider().opacity(0.4) } }
        }
    }
}
