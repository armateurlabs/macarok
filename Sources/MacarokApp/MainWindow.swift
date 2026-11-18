import AppKit
import MacarokAudio
import MacarokCore
import SwiftUI

struct MainWindow: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            TransportBar(model: model, player: model.player)
            Divider()
            GeometryReader { panels in
                HSplitView {
                    LibraryPane(model: model).frame(minWidth: 245, idealWidth: 310, maxWidth: 440, maxHeight: .infinity)
                    ContextPane(model: model).frame(minWidth: 370, idealWidth: 590, maxWidth: .infinity, maxHeight: .infinity)
                    QueuePane(model: model, player: model.player).frame(minWidth: 270, idealWidth: 330, maxWidth: 480, maxHeight: .infinity)
                }
                .environment(\.emptyPanelCenterY, panels.frame(in: .global).midY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 7) {
                if model.isRefreshing { ProgressView().controlSize(.mini); Text(model.refreshProgress) }
                else { Image(systemName: "checkmark").foregroundStyle(.secondary); Text(model.status).lineLimit(1) }
                Spacer(minLength: 15)
                if !model.scanWarnings.isEmpty {
                    Button { model.message = AppMessage(title: "Scan Warnings", detail: model.scanWarnings.prefix(30).joined(separator: "\n")) } label: { Label("\(model.scanWarnings.count)", systemImage: "exclamationmark.triangle") }.buttonStyle(.borderless)
                }
                Text("\(model.queue.count) tracks · \(model.queueDuration.playbackTime)").monospacedDigit()
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 29)
            .background(.bar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(QueueUndoHost(model: model).frame(width: 0, height: 0))
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
        .toolbar {
            ToolbarItem(placement: .principal) { Text("Macarok").font(.headline) }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Appearance", selection: $model.settings.appearance) { ForEach(Appearance.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.inline).labelsHidden()
                } label: { Image(systemName: model.settings.appearance == .dark ? "moon" : model.settings.appearance == .light ? "sun.max" : "display") }.help("Appearance")
                SettingsLink { Image(systemName: "slider.horizontal.3") }.help("Settings")
            }
        }
        .sheet(isPresented: Binding(get: { model.addSourcePresenter == .mainWindow }, set: { if !$0 && model.addSourcePresenter == .mainWindow { model.addSourcePresenter = nil } })) { AddSourceSheet(model: model) }
        .sheet(item: $model.editingTrack) { MetadataEditor(model: model, track: $0) }
        .sheet(item: Binding(get: { model.similarity.request }, set: { model.similarity.request = $0 })) { SimilarPlaylistSheet(model: model, request: $0) }
        .sheet(item: $model.artworkTrack) { ArtworkChooser(model: model, track: $0) }
        .sheet(item: $model.artistArtworkTarget) { ArtistArtworkChooser(model: model, target: $0) }
        .sheet(isPresented: Binding(get: { model.addSourcePresenter == nil && !model.radioDiscoveryOwnsCertificates && !model.certificatePrompts.isEmpty }, set: { if !$0 && model.addSourcePresenter == nil && !model.radioDiscoveryOwnsCertificates { model.answerCertificate(false) } })) {
            if let prompt = model.certificatePrompts.first { CertificateSheet(prompt: prompt, answer: model.answerCertificate) }
        }
        .alert(item: $model.message) { Alert(title: Text($0.title), message: Text($0.detail), dismissButton: .default(Text("OK"))) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers { _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in model.openURL(url) } } } }
            return !providers.isEmpty
        }
    }
}

struct TransportBar: View {
    @Bindable var model: AppModel
    @ObservedObject var player: VLCPlaybackEngine

    var body: some View {
        HStack(spacing: 20) {
            HStack(spacing: 12) {
                Button(action: model.previous) { Image(systemName: "backward.end.fill") }.help("Previous track")
                Button(action: model.togglePlayback) { Image(systemName: [.playing, .opening, .buffering].contains(player.state) || model.playbackIntentQueueID != nil ? "pause.fill" : "play.fill").font(.system(size: 19)).frame(width: 34, height: 34) }
                    .buttonStyle(.bordered).clipShape(Circle()).help("Play / Pause (Space)")
                Button { model.advance() } label: { Image(systemName: "forward.end.fill") }.help("Next track")
            }.buttonStyle(.borderless).disabled(model.queue.isEmpty && model.selectedTrack == nil)
            if let track = model.currentTrack {
                // One boxed unit: artwork, then the track details, then the timeline on the same line.
                HStack(spacing: 12) {
                    TransportArtwork(model: model, track: track).frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Button { model.showCurrentTrack() } label: { Text(track.title).font(.system(size: 13, weight: .semibold)).lineLimit(1) }
                            .buttonStyle(.plain).help("Show “\(track.title)” in the library")
                        TransportSubtitle(model: model, timeline: player.timeline, track: track).font(.system(size: 12))
                    }.frame(minWidth: 150, idealWidth: 300, maxWidth: 320, alignment: .leading).layoutPriority(1)
                    if model.currentIsRadio {
                        HStack(spacing: 7) {
                            Circle().fill(model.radioDisconnected || player.state == .paused ? Color.secondary : .red).frame(width: 5, height: 5)
                            Text(model.radioDisconnected ? "DISCONNECTED" : player.state == .paused ? "PAUSED" : "LIVE").fontWeight(.semibold)
                            Text(model.radioBroadcastTitle ?? "Internet Radio").foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                            if model.radioDisconnected { Button("Reconnect", action: model.reconnectRadio).buttonStyle(.link) }
                        }.font(.system(size: 10)).frame(maxWidth: .infinity)
                    } else {
                        PlaybackTimelineView(model: model, timeline: player.timeline, track: track,
                                             resumePoint: model.seeksResumePoint ? model.restorePosition : nil)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.trailing, 12).frame(height: 48)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 4) { Text("Nothing playing").fontWeight(.medium); Text("Find something in your library and add it to the playlist.").foregroundStyle(.secondary) }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let fraction = model.streamingBufferFraction { ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small).help("Buffering: \(Int(fraction * 100))%") }
            else if player.state == .buffering || player.state == .opening { ProgressView().controlSize(.small).help("Buffering…") }
            HStack(spacing: 7) {
                Image(systemName: "speaker.wave.1").foregroundStyle(.secondary)
                Slider(value: $model.settings.volume, in: 0...1).frame(width: 78).controlSize(.mini).help("Volume")
            }
        }.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
    }
}

/// The playing artwork: a click enlarges it, the context menu changes it.
struct TransportArtwork: View {
    @Bindable var model: AppModel
    let track: TrackRecord
    @State private var zoomed = false

    var body: some View {
        ArtworkView(track: track, model: model, cornerRadius: 0)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { zoomed.toggle() }
            .help("Click to enlarge the artwork")
            .accessibilityAddTraits(.isButton).accessibilityAction(named: Text("Enlarge Artwork")) { zoomed = true }
            .popover(isPresented: $zoomed, arrowEdge: .bottom) { ZoomedArtwork(model: model, track: track) }
            .contextMenu {
                Button("Show Current Track", action: model.showCurrentTrack)
                if !model.isRadioTrack(track) && !model.isPodcastTrack(track) {
                    Button("Choose Artwork…") { model.beginArtworkEditing(track) }
                }
            }
    }
}

/// The artwork at its full resolution, not the list thumbnail.
private struct ZoomedArtwork: View {
    @Bindable var model: AppModel
    let track: TrackRecord
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { ArtworkView(track: track, model: model, cornerRadius: 0) }
        }
        .frame(width: 420, height: 420)
        .task(id: "\(track.artworkPath ?? "")-\(model.artworkRevision)") {
            guard let path = track.artworkPath else { return }
            let loaded = await Task.detached(priority: .userInitiated) { NSImage(contentsOfFile: path) }.value
            if !Task.isCancelled { image = loaded }
        }
        .accessibilityLabel("Artwork for \(track.album)")
    }
}

struct QueuePane: View {
    @Bindable var model: AppModel
    @ObservedObject var player: VLCPlaybackEngine

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader {
                Text("Active Playlist").fontWeight(.semibold).lineLimit(1)
                Text("\(model.queue.count)").foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                PlaylistControls(model: model, location: "top")
            }.accessibilityIdentifier("playlistPanelHeader")
            if let session = model.similarity.session {
                SimilarMixBanner(model: model, similarity: model.similarity, session: session)
                Divider()
            }
            if model.queue.isEmpty {
                ContentUnavailableView { Label("Your playlist is empty", systemImage: "music.note.list") } description: { Text("Double-click or drag library items here.") }
                    .emptyPanel().contentShape(Rectangle())
                    .onDrop(of: [.macarokLibraryItems], isTargeted: nil) { providers in
                        Task { model.insertLibraryItems(await LibraryItemID.load(from: providers), at: 0) }
                        return true
                    }
            } else {
                let rows = PlaylistAlbumGrouping.rows(model.queue, grouped: model.settings.playlistAlbumGroups, isFlat: model.isRadioTrack)
                List(selection: $model.selectedQueueID) {
                    ForEach(rows) { row in
                        switch row {
                        case .header(let header):
                            PlaylistAlbumHeaderRow(model: model, header: header)
                                .moveDisabled(true).deleteDisabled(true).selectionDisabled(true)
                                .listRowBackground(Color.clear)
                        case .entry(let index, let item, let layout):
                            QueueEntryRow(model: model, player: player, index: index, item: item, layout: layout).tag(item.id)
                        }
                    }
                    .onMove { offsets, destination in
                        model.moveQueue(from: PlaylistAlbumGrouping.queueOffsets(offsets, rows: rows),
                                        to: PlaylistAlbumGrouping.queueDestination(destination, rows: rows))
                    }
                    .onDelete { offsets in
                        let entries = PlaylistAlbumGrouping.queueOffsets(offsets, rows: rows)
                        if !entries.isEmpty { model.removeQueue(entries) }
                    }
                    .onInsert(of: [.macarokLibraryItems]) { destination, providers in
                        let index = PlaylistAlbumGrouping.queueDestination(destination, rows: rows)
                        Task { model.insertLibraryItems(await LibraryItemID.load(from: providers), at: index) }
                    }
                    let similarity = model.similarity
                    if similarity.isMixing, similarity.session?.suggestionID == nil, similarity.isSearching || similarity.error != nil {
                        SimilarMixStatusRow(similarity: similarity).selectionDisabled(true).listRowBackground(Color.clear)
                    }
                }.listStyle(.inset(alternatesRowBackgrounds: true))
                // Row gestures would intercept the native drag that reorders entries.
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first, let item = model.queue.first(where: { $0.id == id }) { QueueEntryMenu(model: model, item: item) }
                } primaryAction: { ids in
                    if let id = model.queue.first(where: { ids.contains($0.id) })?.id { model.playQueueItem(id) }
                }
                .background(NativeListBackground(revision: Self.backgroundRevision(model.queueRevision, rows: rows)) { [weak model] table in model?.activePlaylistTable = table })
                .onDeleteCommand { if let id = model.selectedQueueID, let index = model.queue.firstIndex(where: { $0.id == id }) { model.removeQueue(IndexSet(integer: index)) } }
            }
            PlaylistPanelFooter(model: model)
        }
    }

    /// Headers change row heights and counts without changing the queue revision.
    private static func backgroundRevision(_ queueRevision: Int, rows: [PlaylistRow]) -> Int {
        var hasher = Hasher()
        hasher.combine(queueRevision)
        for row in rows { hasher.combine(row.id) }
        return hasher.finalize()
    }
}

private struct QueueEntryRow: View {
    @Bindable var model: AppModel
    @ObservedObject var player: VLCPlaybackEngine
    let index: Int
    let item: QueueItem
    let layout: PlaylistEntryLayout

    var body: some View {
        HStack(spacing: 9) {
            if layout == .single { ArtworkView(track: item.track, model: model).frame(width: 34, height: 34) }
            Group {
                if item.id == model.currentQueueID { Image(systemName: player.state == .playing ? "waveform" : "pause.fill").foregroundStyle(Color.accentColor) }
                else if isSuggestion { Image(systemName: "sparkles").foregroundStyle(Color.accentColor).help("Suggested next track") }
                else { Text(String(format: "%02d", index + 1)).foregroundStyle(.tertiary) }
            }.font(.system(size: 10)).frame(width: 19)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.track.title).fontWeight(item.id == model.currentQueueID ? .semibold : .regular).lineLimit(1, reservesSpace: true)
                // Grouped entries omit an empty detail line, so album bodies stay compact under their header.
                // Their source is named once in the album header.
                if layout != .grouped || !subtitle.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1, reservesSpace: true)
                        if layout != .grouped && model.playlistShowsSources {
                            SourceBadge(model: model, sourceID: item.track.sourceID, compact: true)
                                .frame(maxWidth: 80, alignment: .leading).layoutPriority(1)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 3)
            Text(model.isRadioTrack(item.track) ? "LIVE" : item.track.formattedDuration)
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }.font(.system(size: 12)).padding(.vertical, 4).padding(.leading, layout == .grouped ? 8 : 0)
            .padding(.horizontal, isSuggestion ? 6 : 0)
            .modifier(OptionalSuggestionFrame(active: isSuggestion, highlighted: model.selectedQueueID == item.id))
            .contentShape(Rectangle())
    }

    private var isSuggestion: Bool { model.similarity.isSuggestion(item.id) }

    private var subtitle: String {
        let details: [String]
        // The announced track names its artist and why it was chosen; the album would truncate the reason.
        if isSuggestion {
            let reason = model.similarity.session.map { "Up next, similar to \($0.suggestionReason)" } ?? ""
            return [item.track.artist, reason].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        switch layout {
        case .plain: details = [item.track.artist]
        case .single: details = [[item.track.artist, item.track.album].filter { !$0.isEmpty }.joined(separator: " — ")]
        // The header already names the album artist; repeat a track artist only when it differs.
        case .grouped: details = [item.track.artist == item.track.albumArtist ? "" : item.track.artist]
        }
        return (details + [item.track.isCUETrack ? "CUE" : ""]).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct OptionalSuggestionFrame: ViewModifier {
    let active: Bool
    let highlighted: Bool
    func body(content: Content) -> some View {
        if active { content.modifier(SuggestionFrame(highlighted: highlighted)) } else { content }
    }
}

private struct QueueEntryMenu: View {
    @Bindable var model: AppModel
    let item: QueueItem
    var body: some View {
        let similarity = model.similarity
        if similarity.isSuggestion(item.id) {
            Button { similarity.skipSuggestion() } label: { Label("Skip Suggestion", systemImage: "forward.end") }
        }
        Button("Play Now") { model.playQueueItem(item.id) }
        Button("Show in Library") { if !model.scopeIncludes(sourceID: item.track.sourceID) { model.sourceID = item.track.sourceID }; model.inspect(item.track) }
        TrackFileActions(model: model, track: item.track)
        Divider()
        if let session = similarity.session {
            Button("Restore Skipped Tracks (\(session.skippedCount))") { similarity.restoreSkipped() }.disabled(session.skippedCount == 0)
            Button("Stop Mix") { similarity.end() }
        } else {
            SimilarityActions(model: model) { [item.track] }
        }
        Divider()
        Button("Remove from Playlist", role: .destructive) { if let index = model.queue.firstIndex(where: { $0.id == item.id }) { model.removeQueue(IndexSet(integer: index)) } }
    }
}

/// Amarok-inspired album heading. It is not a queue entry: it cannot be selected, moved, or deleted.
private struct PlaylistAlbumHeaderRow: View {
    @Bindable var model: AppModel
    let header: PlaylistAlbumHeader

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(track: header.track, model: model).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(header.album).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text([header.artist, header.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    // Groups only join entries from one source.
                    if model.playlistShowsSources {
                        SourceBadge(model: model, sourceID: header.track.sourceID, compact: true)
                            .frame(maxWidth: 80, alignment: .leading).layoutPriority(1)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text("\(header.offsets.count) tracks · \(header.duration.playbackTime)")
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
        }.padding(.top, 8).padding(.bottom, 3).contentShape(Rectangle())
            .accessibilityElement(children: .combine).accessibilityIdentifier("playlistAlbumHeader")
            .onTapGesture(count: 2) { model.playQueueItem(header.firstEntryID) }
            .contextMenu {
                Button("Play Album") { model.playQueueItem(header.firstEntryID) }
                Button("Show Album in Library") { model.inspectAlbum(containing: header.track) }
                Divider()
                Button("Remove Album from Playlist", role: .destructive) { removeGroup() }
            }
    }

    private func removeGroup() {
        // Offsets are re-resolved by entry identity in case the queue changed since this row rendered.
        guard let first = model.queue.firstIndex(where: { $0.id == header.firstEntryID }) else { return }
        let end = min(model.queue.count, first + header.offsets.count)
        model.removeQueue(IndexSet(integersIn: first..<end))
    }
}

struct PlaylistControls: View {
    @Bindable var model: AppModel
    let location: String

    var body: some View {
        HStack(spacing: 5) {
            Button(action: model.shuffleQueue) { Image(systemName: "shuffle").frame(width: 22, height: 23) }
                .help("Shuffle playlist").accessibilityLabel("Shuffle playlist")
                .accessibilityIdentifier("playlistShuffle-\(location)").disabled(model.queue.count < 2 || model.similarity.isMixing)
            Button(action: model.cycleRepeat) {
                Image(systemName: model.settings.repeatMode.symbol).frame(width: 22, height: 23)
                    .background(model.settings.repeatMode == .none ? Color.clear : Color.accentColor.opacity(0.17), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(model.settings.repeatMode == .none ? Color.secondary : Color.accentColor)
            }
            .help("Repeat: \(model.settings.repeatMode.title) · Next: \(model.settings.repeatMode.next.title)")
            .accessibilityLabel("Repeat: \(model.settings.repeatMode.title)").accessibilityIdentifier("playlistRepeat-\(location)")
            .disabled(model.similarity.isMixing)
            Button(action: model.clearQueue) { Image(systemName: "trash").frame(width: 22, height: 23) }
                .help("Clear playlist").accessibilityLabel("Clear playlist")
                .accessibilityIdentifier("playlistClear-\(location)").disabled(model.queue.isEmpty)
            Menu {
                Toggle("Show Album Groups", isOn: $model.settings.playlistAlbumGroups)
                Toggle("Show Sources", isOn: $model.settings.playlistShowsSources).disabled(!model.isAllSources)
                Divider()
                Button("Save Playlist…", action: model.savePlaylist).disabled(model.queue.isEmpty)
                Button("Export Playlist…", action: model.exportPlaylist).disabled(model.queue.isEmpty)
            } label: { Image(systemName: "ellipsis").frame(width: 22, height: 23) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Playlist actions").accessibilityLabel("Playlist actions").accessibilityIdentifier("playlistMore-\(location)")
        }
        .font(.system(size: 12)).buttonStyle(.borderless).fixedSize().layoutPriority(1)
    }
}

struct ArtworkView: View {
    let track: TrackRecord?
    var model: AppModel?
    var cornerRadius: CGFloat = 5

    var body: some View {
        ArtworkImageView(path: track?.artworkPath, revision: model?.artworkRevision ?? 0, placeholder: "opticaldisc",
                         cornerRadius: cornerRadius, accessibilityLabel: track.map { "Artwork for \($0.album)" } ?? "No artwork")
            .task(id: "\(track?.artworkPath ?? track?.id ?? "")-\(model?.artworkRevision ?? 0)") {
                if track?.artworkPath == nil, let track { await model?.ensureArtwork(track) }
            }
    }
}

/// Decoded artwork kept on the main actor, so a view can draw an image it has seen before
/// in its first frame instead of flashing a placeholder or the previous item's picture.
@MainActor
enum ArtworkMemoryCache {
    private static let cache: NSCache<NSString, NSImage> = { let cache = NSCache<NSString, NSImage>(); cache.countLimit = 200; return cache }()
    static func key(path: String, revision: Int) -> String { "\(revision):\(path)" }
    static func image(forKey key: String) -> NSImage? { cache.object(forKey: key as NSString) }
    static func store(_ image: NSImage, forKey key: String) { cache.setObject(image, forKey: key as NSString) }
}

/// Square artwork with a symbol placeholder. Only an image loaded for the current path is ever shown.
struct ArtworkImageView: View {
    let path: String?
    var revision = 0
    var placeholder = "opticaldisc"
    var cornerRadius: CGFloat = 5
    var accessibilityLabel = "Artwork"
    @State private var loaded: (key: String, image: NSImage)?

    private var key: String? { path.map { ArtworkMemoryCache.key(path: $0, revision: revision) } }
    private var image: NSImage? {
        guard let key else { return nil }
        if let loaded, loaded.key == key { return loaded.image }
        return ArtworkMemoryCache.image(forKey: key)
    }

    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                if let image {
                    GeometryReader { geometry in
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: max(0, geometry.size.width), height: max(0, geometry.size.height))
                            .clipped()
                    }
                } else {
                    GeometryReader { geometry in
                        Image(systemName: placeholder).resizable().scaledToFit().foregroundStyle(.tertiary)
                            .padding(max(13, min(geometry.size.width, geometry.size.height) * 0.3))
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
            }
            .clipped().clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .transaction { $0.animation = nil }
            .task(id: key) {
                guard let key, let path, image == nil else { return }
                let thumbnail = await ArtworkThumbnailCache.shared.image(at: path, revision: revision, pixelSize: 512)
                guard !Task.isCancelled, let thumbnail else { return }
                let decoded = NSImage(cgImage: thumbnail.cgImage, size: .zero)
                ArtworkMemoryCache.store(decoded, forKey: key)
                loaded = (key, decoded)
            }
            .accessibilityLabel(accessibilityLabel)
    }
}

struct TrackLine: View {
    let track: TrackRecord
    @Bindable var model: AppModel
    var showsArtist = false
    /// Inside a selectable List, the list owns click, double-click, and drag behavior.
    var usesListSelection = false
    var body: some View {
        HStack(spacing: 7) {
            Text(track.trackNumber.map { String(format: "%02d", $0) } ?? "").font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                if showsArtist { Text(track.artist).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                SourceBadge(model: model, sourceID: track.sourceID)
            }
            if track.isCUETrack { Text("CUE").font(.system(size: 8, weight: .medium)).padding(.horizontal, 3).background(.quaternary, in: RoundedRectangle(cornerRadius: 2)).foregroundStyle(.secondary) }
            Spacer(minLength: 4)
            Text(track.formattedDuration).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
        }.font(.system(size: 12)).padding(.vertical, 3).contentShape(Rectangle())
            .onLibraryClick(enabled: !usesListSelection, inspect: { model.inspect(track) }, add: { model.doubleClick(track) })
            .contextMenu {
                LibraryPlaybackActions(model: model) { [track] }
                Divider()
                Button("Edit Song Metadata…") { model.beginMetadataEditing(track) }
                Button("Edit Album Metadata…") { model.beginAlbumMetadataEditing(track) }
                Button("Choose Artwork…") { model.beginArtworkEditing(track) }
                TrackFileActions(model: model, track: track)
            }
    }
}

extension View {
    /// Resolves a double-click before a single-click can replace the inspected view.
    /// Disabled inside selectable Lists: row gestures would block native selection and dragging there.
    func onLibraryClick(enabled: Bool = true, inspect: @escaping () -> Void, add: @escaping () -> Void) -> some View {
        gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { result in
            switch result { case .first: add(); case .second: inspect() }
        }, including: enabled ? .all : .subviews)
        .accessibilityAction(named: Text("Inspect"), inspect)
        .accessibilityAction(named: Text("Add to Active Playlist"), add)
    }
}
