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
                    .emptyPanel()
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

/// The station's directory logo, or the same symbol placeholder as folder pages.
private struct RadioStationArtwork: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary).overlay { image.resizable().scaledToFit() }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else { ContextSymbolArtwork(systemImage: "antenna.radiowaves.left.and.right") }
        }.accessibilityHidden(true)
    }
}

/// A station page in the same layout as artist and album pages: the station's directory listing first,
/// then what its stream announces, then the stream's technical details.
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
    private var station: RadioStationRecord? {
        guard let track = displayedTrack else { return nil }
        return model.radio?.stations.first { $0.id == track.id && $0.sourceID == track.sourceID }
    }
    private var announced: RadioStreamInfo? { showsCurrentBroadcast ? model.radioStreamInfo : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ContextLayout.sectionSpacing) {
                ContextHeader(eyebrow: eyebrow) {
                    RadioStationArtwork(url: station?.artworkURL.flatMap(URL.init(string:)))
                } details: {
                    Text(displayedTrack?.title ?? announced?.name ?? "Internet Radio").font(ContextLayout.titleFont).lineLimit(2)
                    Label(statusTitle, systemImage: statusSymbol).font(.system(size: 12)).foregroundStyle(.secondary)
                    if showsCurrentBroadcast, let title = model.radioBroadcastTitle {
                        Text(title).font(.system(size: 13)).lineLimit(2).textSelection(.enabled)
                    }
                    if let genre { Text(genre).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
                }
                actions
                Divider()
                if let description = announced?.description {
                    Text(description).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                    ForEach(details, id: \.label) { detail in
                        GridRow {
                            Text(detail.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(detail.value).textSelection(.enabled)
                        }
                    }
                }.font(.system(size: 12))
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
    }

    private var eyebrow: String {
        ["Radio Station", station?.country ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var statusTitle: String {
        guard showsCurrentBroadcast else { return "Not playing" }
        return model.radioDisconnected ? "Disconnected" : player.state == .paused ? "Paused" : "Live"
    }
    private var statusSymbol: String {
        guard showsCurrentBroadcast else { return "antenna.radiowaves.left.and.right" }
        return model.radioDisconnected ? "wifi.slash" : player.state == .paused ? "pause.circle" : "dot.radiowaves.left.and.right"
    }
    private var genre: String? {
        let tags = station?.tags ?? displayedTrack?.genre ?? ""
        let value = tags.isEmpty ? announced?.genre : tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
        return value?.isEmpty == false ? value : nil
    }
    private var homepage: URL? {
        station?.homepage.flatMap { URL(string: $0) }.flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil } ?? announced?.homepage
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if showsCurrentBroadcast && model.radioDisconnected {
                Button { model.reconnectRadio() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }.buttonStyle(.borderedProminent)
            } else if !showsCurrentBroadcast, let station, let controller = model.radio {
                Button { Task { await controller.addToPlaylist(station, playNow: true) } } label: { Label("Play Now", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).disabled(station.isHLS)
            }
            if let station, let controller = model.radio {
                let favorite = controller.stations.first { $0.id == station.id }?.isFavorite ?? station.isFavorite
                Button { Task { if favorite { await controller.removeFavorite(station) } else { await controller.saveFavorite(station) } } } label: {
                    Label(favorite ? "Favorite" : "Add to Favorites", systemImage: favorite ? "star.fill" : "star")
                }.help(favorite ? "Remove from Favorites" : "Add to Favorites")
            }
            if let homepage {
                Button { NSWorkspace.shared.open(homepage) } label: { Label("Website", systemImage: "safari") }.help(homepage.absoluteString)
            }
            Spacer(minLength: 0)
        }.controlSize(.small)
    }

    private struct Detail { let label: String; let value: String }
    /// The directory listing comes first; the stream's own headers fill what it lacks.
    private var details: [Detail] {
        var rows: [Detail] = []
        func add(_ label: String, _ value: String?) { if let value, !value.isEmpty { rows.append(Detail(label: label, value: value)) } }
        if let announcedName = announced?.name, announcedName != displayedTrack?.title { add("Announced as", announcedName) }
        add("Country", station?.country)
        add("Language", station?.language.localizedCapitalized)
        let codec = station?.codec.isEmpty == false ? station?.codec : announced?.contentType.map(Self.format)
        add("Format", codec ?? (displayedTrack?.format == "RADIO" ? nil : displayedTrack?.format))
        let bitrate = station.flatMap { $0.bitrate > 0 ? $0.bitrate : nil } ?? announced?.bitrate
        add("Bitrate", bitrate.map { "\($0) kbps" })
        add("Sample rate", announced?.sampleRate.map { String(format: "%.1f kHz", Double($0) / 1_000) })
        add("Stream", (station?.streamURL ?? displayedTrack?.fileURL).flatMap { URL(string: $0)?.host })
        add("Listed in", station?.directoryID == nil ? nil : "Radio Browser")
        return rows
    }
    private static func format(_ contentType: String) -> String {
        switch contentType {
        case "audio/mpeg", "audio/mp3": "MP3"
        case "audio/aac", "audio/aacp", "audio/x-aac": "AAC"
        case "audio/ogg", "application/ogg": "Ogg"
        case "audio/opus": "Opus"
        case "audio/flac", "audio/x-flac": "FLAC"
        default: contentType
        }
    }
}
