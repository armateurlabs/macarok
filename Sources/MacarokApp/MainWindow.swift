import AppKit
import MacarokAudio
import MacarokCore
import SwiftUI

struct MainWindow: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TransportBar(model: model, player: model.player)
            Divider()
            HSplitView {
                LibraryPane(model: model).frame(minWidth: 245, idealWidth: 310, maxWidth: 440, maxHeight: .infinity)
                ContextPane(model: model).frame(minWidth: 370, idealWidth: 590, maxWidth: .infinity, maxHeight: .infinity)
                QueuePane(model: model, player: model.player).frame(minWidth: 270, idealWidth: 330, maxWidth: 480, maxHeight: .infinity)
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
        .toolbar {
            ToolbarItem(placement: .principal) { Text("Macarok").font(.headline) }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Appearance", selection: $model.settings.appearance) { ForEach(Appearance.allCases) { Text($0.title).tag($0) } }
                } label: { Image(systemName: model.settings.appearance == .dark ? "moon" : model.settings.appearance == .light ? "sun.max" : "display") }.help("Appearance")
                SettingsLink { Image(systemName: "slider.horizontal.3") }.help("Settings")
            }
        }
        .sheet(isPresented: Binding(get: { model.addSourcePresenter == .mainWindow }, set: { if !$0 && model.addSourcePresenter == .mainWindow { model.addSourcePresenter = nil } })) { AddSourceSheet(model: model) }
        .sheet(item: $model.editingTrack) { MetadataEditor(model: model, track: $0) }
        .sheet(item: $model.artworkTrack) { ArtworkChooser(model: model, track: $0) }
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
    @State private var dragging = false
    @State private var seekPosition: Double = 0

    var body: some View {
        HStack(spacing: 24) {
            HStack(spacing: 12) {
                Button(action: model.previous) { Image(systemName: "backward.end.fill") }.help("Previous track")
                Button(action: model.togglePlayback) { Image(systemName: [.playing, .opening, .buffering].contains(player.state) || model.playbackIntentQueueID != nil ? "pause.fill" : "play.fill").font(.system(size: 19)).frame(width: 34, height: 34) }
                    .buttonStyle(.bordered).clipShape(Circle()).help("Play / Pause (Space)")
                Button { model.advance() } label: { Image(systemName: "forward.end.fill") }.help("Next track")
            }.buttonStyle(.borderless).disabled(model.queue.isEmpty && model.selectedTrack == nil)
            if let track = model.currentTrack {
                ArtworkView(track: track, model: model).frame(width: 46, height: 46)
                VStack(spacing: 5) {
                    HStack {
                        Button { model.showCurrentTrack() } label: { Text(track.title).fontWeight(.medium).lineLimit(1) }.buttonStyle(.plain)
                        Spacer()
                        Text(track.artist).foregroundStyle(.secondary).lineLimit(1)
                    }.font(.system(size: 12))
                    if model.currentIsRadio {
                        HStack(spacing: 7) {
                            Circle().fill(model.radioDisconnected || player.state == .paused ? Color.secondary : .red).frame(width: 5, height: 5)
                            Text(model.radioDisconnected ? "DISCONNECTED" : player.state == .paused ? "PAUSED" : "LIVE").fontWeight(.semibold)
                            Text(model.radioBroadcastTitle ?? "Internet Radio").foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                            if model.radioDisconnected { Button("Reconnect", action: model.reconnectRadio).buttonStyle(.link) }
                        }.font(.system(size: 10))
                    } else {
                    HStack(spacing: 8) {
                        Text((dragging ? seekPosition : player.position).playbackTime).frame(width: 43, alignment: .trailing)
                        Slider(value: Binding(get: { dragging ? seekPosition : min(player.position, max(1, player.duration)) }, set: { seekPosition = $0 }), in: 0...max(1, player.duration > 0 ? player.duration : track.duration), onEditingChanged: { editing in
                            if editing { seekPosition = player.position; dragging = true }
                            else { model.seekPlayback(to: seekPosition); dragging = false }
                        }).controlSize(.mini).disabled(!player.isSeekable)
                        Text((player.duration > 0 ? player.duration : track.duration).playbackTime).frame(width: 43, alignment: .leading)
                    }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) { Text("Nothing playing").fontWeight(.medium); Text("Find something in your library and add it to the playlist.").foregroundStyle(.secondary) }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let fraction = model.streamingBufferFraction { ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small).help("Buffering: \(Int(fraction * 100))%") }
            else if player.state == .buffering || player.state == .opening { ProgressView().controlSize(.small).help("Buffering…") }
            HStack(spacing: 7) {
                Image(systemName: "speaker.wave.1").foregroundStyle(.secondary)
                Slider(value: $model.settings.volume, in: 0...1).frame(width: 78).controlSize(.mini).help("Volume")
            }
        }.padding(.horizontal, 20).padding(.vertical, 13).background(.bar)
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
            if model.queue.isEmpty {
                ContentUnavailableView { Label("Your playlist is empty", systemImage: "music.note.list") } description: { Text("Double-click a library track to add it here.") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedQueueID) {
                    ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 9) {
                            Group {
                                if item.id == model.currentQueueID { Image(systemName: player.state == .playing ? "waveform" : "pause.fill").foregroundStyle(Color.accentColor) }
                                else { Text(String(format: "%02d", index + 1)).foregroundStyle(.tertiary) }
                            }.font(.system(size: 10)).frame(width: 19)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.track.title).fontWeight(item.id == model.currentQueueID ? .semibold : .regular).lineLimit(1)
                                Text(item.track.artist + (item.track.isCUETrack ? " · CUE" : "")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                SourceBadge(model: model, sourceID: item.track.sourceID)
                            }
                            Spacer(minLength: 3)
                            Text(model.isRadioTrack(item.track) ? "LIVE" : item.track.formattedDuration)
                                .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                        }.font(.system(size: 12)).padding(.vertical, 4).contentShape(Rectangle()).tag(item.id)
                            .onTapGesture(count: 2) { model.playQueueItem(item.id) }
                            .contextMenu { Button("Play Now") { model.playQueueItem(item.id) }; Button("Show in Library") { if !model.scopeIncludes(sourceID: item.track.sourceID) { model.sourceID = item.track.sourceID }; model.inspect(item.track) }; Divider(); Button("Remove from Playlist", role: .destructive) { if let index = model.queue.firstIndex(where: { $0.id == item.id }) { model.removeQueue(IndexSet(integer: index)) } } }
                    }.onMove(perform: model.moveQueue).onDelete(perform: model.removeQueue)
                }.listStyle(.inset(alternatesRowBackgrounds: true))
                .onDeleteCommand { if let id = model.selectedQueueID, let index = model.queue.firstIndex(where: { $0.id == id }) { model.removeQueue(IndexSet(integer: index)) } }
            }
            Divider()
            HStack { Spacer(minLength: 0); PlaylistControls(model: model, location: "bottom") }
                .padding(.horizontal, 13).frame(height: 42).background(.bar)
                .accessibilityIdentifier("playlistPanelFooter")
        }
    }
}

struct PlaylistControls: View {
    @Bindable var model: AppModel
    let location: String

    var body: some View {
        HStack(spacing: 5) {
            Button(action: model.shuffleQueue) { Image(systemName: "shuffle").frame(width: 22, height: 23) }
                .help("Shuffle playlist").accessibilityLabel("Shuffle playlist")
                .accessibilityIdentifier("playlistShuffle-\(location)").disabled(model.queue.count < 2)
            Button(action: model.cycleRepeat) {
                Image(systemName: model.settings.repeatMode.symbol).frame(width: 22, height: 23)
                    .background(model.settings.repeatMode == .none ? Color.clear : Color.accentColor.opacity(0.17), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(model.settings.repeatMode == .none ? Color.secondary : Color.accentColor)
            }
            .help("Repeat: \(model.settings.repeatMode.title) · Next: \(model.settings.repeatMode.next.title)")
            .accessibilityLabel("Repeat: \(model.settings.repeatMode.title)").accessibilityIdentifier("playlistRepeat-\(location)")
            Button(action: model.clearQueue) { Image(systemName: "trash").frame(width: 22, height: 23) }
                .help("Clear playlist").accessibilityLabel("Clear playlist")
                .accessibilityIdentifier("playlistClear-\(location)").disabled(model.queue.isEmpty)
            Menu {
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
    @State private var image: NSImage?

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
                    Image(systemName: "opticaldisc").resizable().scaledToFit().foregroundStyle(.tertiary).padding(13)
                }
            }
            .clipped().clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: "\(track?.artworkPath ?? track?.id ?? "")-\(model?.artworkRevision ?? 0)") {
            if let path = track?.artworkPath {
                let data = await Task.detached(priority: .utility) { try? Data(contentsOf: URL(fileURLWithPath: path)) }.value
                image = data.flatMap(NSImage.init(data:))
            } else { image = nil; if let track { await model?.ensureArtwork(track) } }
        }
        .accessibilityLabel(track.map { "Artwork for \($0.album)" } ?? "No artwork")
    }
}

struct TrackLine: View {
    let track: TrackRecord
    @Bindable var model: AppModel
    var showsArtist = false
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
            .onLibraryClick(inspect: { model.inspect(track) }, add: { model.doubleClick(track) })
            .contextMenu {
                LibraryPlaybackActions(model: model) { [track] }
                Divider()
                Button("Edit Metadata…") { model.editingTrack = track }
                Button("Choose Artwork…") { model.artworkTrack = track }
                if let url = track.url, url.isFileURL { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            }
    }
}

extension View {
    /// Resolves a double-click before a single-click can replace the inspected view.
    func onLibraryClick(inspect: @escaping () -> Void, add: @escaping () -> Void) -> some View {
        gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { result in
            switch result { case .first: add(); case .second: inspect() }
        })
        .accessibilityAction(named: Text("Inspect"), inspect)
        .accessibilityAction(named: Text("Add to Active Playlist"), add)
    }
}
