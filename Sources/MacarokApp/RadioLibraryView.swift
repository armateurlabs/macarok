import MacarokCore
import MacarokAudio
import SwiftUI

struct RadioLibraryView: View {
    @Bindable var model: AppModel
    @State private var favoritesOnly = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var showsDiscovery = false
    @State private var showsAddURL = false

    private var stations: [RadioStationRecord] {
        model.radioStations.filter { station in
            (!favoritesOnly || station.isFavorite) && (query.isEmpty || (station.title + " " + station.description + " " + station.tags).localizedStandardContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 11) {
                SearchField(prompt: "Search saved stations", text: $query, focus: $searchFocused)
                Picker("Radio view", selection: $favoritesOnly) {
                    Text("Stations").tag(false)
                    Text("Favorites").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                HStack {
                    Button { showsDiscovery = true } label: { Label("Browse…", systemImage: "magnifyingglass") }
                    Spacer(minLength: 3)
                    Button { showsAddURL = true } label: { Label("Add URL…", systemImage: "plus") }
                }.font(.system(size: 11)).buttonStyle(.borderless).disabled(model.radio == nil)
            }.padding(12)
            if stations.isEmpty {
                ContentUnavailableView(favoritesOnly ? "No Favorite Stations" : "No Stations", systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text(query.isEmpty ? "Browse the directory or add a stream URL." : "Try another station name."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(stations) { station in
                    RadioStationLabel(station: station)
                        .padding(.vertical, 4).contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            Task { await model.radio?.addToPlaylist(station, playNow: model.queue.isEmpty) }
                        }
                        .contextMenu {
                            if let controller = model.radio { RadioStationActions(controller: controller, station: station) }
                        }
                }.listStyle(.inset(alternatesRowBackgrounds: true))
                    .background(NativeListBackground(revision: stations.hashValue))
            }
            if let error = model.radio?.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 13).padding(.bottom, 8)
            }
            LibraryPanelFooter(model: model, summary: .radio(stations: stations.count))
        }
        .sheet(isPresented: $showsDiscovery) { if let controller = model.radio { RadioDiscoverySheet(controller: controller, model: model) } }
        .sheet(isPresented: $showsAddURL) { if let controller = model.radio { AddRadioURLSheet(controller: controller) } }
    }
}

struct RadioStationLabel: View {
    let station: RadioStationRecord
    var favoriteOverride: Bool?
    var body: some View {
        HStack(spacing: 10) {
            DirectoryArtwork(url: station.artworkURL.flatMap(URL.init(string:)), symbol: "antenna.radiowaves.left.and.right")
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(station.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                if !station.description.isEmpty { Text(station.description).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                if station.isHLS { Text("HLS is not supported").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            if favoriteOverride ?? station.isFavorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RadioStationActions: View {
    @Bindable var controller: RadioController
    let station: RadioStationRecord
    var body: some View {
        Button("Play Now") { Task { await controller.addToPlaylist(station, playNow: true) } }.disabled(station.isHLS)
        Button("Add to Active Playlist") { Task { await controller.addToPlaylist(station) } }.disabled(station.isHLS)
        Button("Add After Current Track") { Task { await controller.addToPlaylist(station, afterCurrent: true) } }.disabled(station.isHLS)
        Divider()
        if controller.stations.first(where: { $0.id == station.id })?.isFavorite ?? station.isFavorite {
            Button("Remove from Favorites") { Task { await controller.removeFavorite(station) } }
        } else {
            Button("Add to Favorites") { Task { await controller.saveFavorite(station) } }
        }
    }
}

struct AddRadioURLSheet: View {
    @Bindable var controller: RadioController
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var isAdding = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Add Radio Station").font(.title2.weight(.semibold))
            TextField("Station name", text: $name)
            TextField("Stream URL", text: $address, prompt: Text("https://example.com/live.mp3"))
                .textContentType(.URL).autocorrectionDisabled()
            Text("Use a direct stream URL, M3U, or PLS playlist.").font(.caption).foregroundStyle(.secondary)
            if let error = controller.errorMessage { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                if isAdding { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Station") {
                    isAdding = true
                    task = Task { @MainActor in
                        defer { isAdding = false }
                        await controller.addURL(name: name, address: address)
                        if !Task.isCancelled, controller.errorMessage == nil { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(isAdding || (try? RadioError.validatedURL(address)) == nil)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 480)
            .onDisappear { task?.cancel() }
    }
}

struct RadioFavoritesSection: View {
    @Bindable var model: AppModel
    var body: some View {
        let favorites = model.radioStations.filter(\.isFavorite)
        if !favorites.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Radio Favorites").font(.system(size: 14, weight: .semibold))
                ForEach(favorites) { station in
                    RadioStationLabel(station: station).padding(.vertical, 3).contentShape(Rectangle())
                        .onTapGesture(count: 2) { Task { await model.radio?.addToPlaylist(station, playNow: model.queue.isEmpty) } }
                        .contextMenu { if let controller = model.radio { RadioStationActions(controller: controller, station: station) } }
                }
            }
        }
    }
}

struct RadioNowPlayingView: View {
    @Bindable var model: AppModel
    private let inspectedTrack: TrackRecord?
    @ObservedObject private var player: VLCPlaybackEngine
    init(model: AppModel, track: TrackRecord? = nil) {
        self.model = model; inspectedTrack = track
        _player = ObservedObject(wrappedValue: model.player)
    }

    var displayedTrack: TrackRecord? { inspectedTrack ?? model.currentTrack }
    var showsCurrentBroadcast: Bool {
        guard let track = displayedTrack, let current = model.currentTrack else { return false }
        return model.isRadioTrack(current) && track.id == current.id && track.sourceID == current.sourceID
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 56)).foregroundStyle(.secondary)
            Text(displayedTrack?.title ?? "Internet Radio").font(.title.weight(.semibold)).multilineTextAlignment(.center)
            if showsCurrentBroadcast {
                Label(model.radioDisconnected ? "Disconnected" : player.state == .paused ? "Paused" : "Live Radio", systemImage: model.radioDisconnected ? "wifi.slash" : player.state == .paused ? "pause.circle" : "dot.radiowaves.left.and.right")
                    .font(.callout).foregroundStyle(.secondary)
                if let title = model.radioBroadcastTitle, !title.isEmpty { Text(title).font(.title3).multilineTextAlignment(.center).textSelection(.enabled) }
                if model.radioDisconnected { Button("Reconnect", action: model.reconnectRadio).buttonStyle(.borderedProminent) }
            } else {
                Label("Radio Station", systemImage: "antenna.radiowaves.left.and.right").font(.callout).foregroundStyle(.secondary)
                if let track = displayedTrack,
                   let station = model.radio?.stations.first(where: { $0.id == track.id && $0.sourceID == track.sourceID }),
                   !station.description.isEmpty {
                    Text(station.description).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
