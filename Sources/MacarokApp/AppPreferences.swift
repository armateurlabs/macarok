import Foundation
import SwiftUI
import KeyboardShortcuts

enum Appearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? { self == .system ? nil : self == .dark ? .dark : .light }
}

enum RepeatMode: String, Codable, CaseIterable {
    case none, playlist, track
    var next: Self { self == .none ? .playlist : self == .playlist ? .track : .none }
    var title: String { rawValue.capitalized }
    var symbol: String { self == .track ? "repeat.1" : "repeat" }
}

enum LibraryView: String, CaseIterable, Identifiable {
    case home, artists, albums, years, folders, tags
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self { case .home: "house"; case .artists: "person.2"; case .albums: "square.stack"; case .years: "calendar"; case .folders: "folder"; case .tags: "tag" }
    }
}

enum ContextPage { case home, track, album, artist, folder }

enum CenterPage: String, CaseIterable, Identifiable {
    case home, playing
    var id: String { rawValue }
    var title: String { self == .home ? "Home" : "Playing" }
}

enum HomeFilter: String, CaseIterable, Identifiable {
    case all, recentlyAdded, recentlyPlayed, mostPlayed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .recentlyAdded: "Recently added"
        case .recentlyPlayed: "Recently played"
        case .mostPlayed: "Most played"
        }
    }
}

enum ContextMode: String, Codable, CaseIterable, Identifiable {
    case context, lyrics, wikipedia, editMetadata, editAlbumMetadata
    var id: String { rawValue }
    var title: String {
        switch self { case .editMetadata: "Edit song metadata"; case .editAlbumMetadata: "Edit album metadata"; default: rawValue.capitalized }
    }
}

enum AddSourcePresenter: String, Identifiable {
    case mainWindow, settings
    var id: String { rawValue }
}

enum TrackDoubleClickAction: String, Codable, CaseIterable, Identifiable {
    case append, afterCurrent, playNow
    var id: String { rawValue }
    var title: String {
        switch self { case .append: "Add to Playlist"; case .afterCurrent: "Add After Current Track"; case .playNow: "Play Now" }
    }
}

enum PlayingAutoSwitchMode: String, Codable, CaseIterable, Identifiable {
    case manualTrackStart, oncePerLaunch, playbackSessionStart
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manualTrackStart: "Every manually started track"
        case .oncePerLaunch: "First playback after app launch"
        case .playbackSessionStart: "First playback after Stop or playlist end"
        }
    }
}

struct AppPreferences: Codable {
    var appearance: Appearance = .system
    var showMenuBar = false
    var repeatMode: RepeatMode = .none
    var trackDoubleClickAction: TrackDoubleClickAction = .append
    var playingAutoSwitchMode: PlayingAutoSwitchMode = .manualTrackStart
    var doubleClickPlays: Bool {
        get { trackDoubleClickAction == .playNow }
        set { trackDoubleClickAction = newValue ? .playNow : .append }
    }
    var customBuffer = false
    var bufferSeconds: Double = 20
    var volume: Double = 0.75
    var localShortcuts: [String: Data] = [:]
    var librarySortOrder = LibrarySortOrder()
    var playlistAlbumGroups = false
    var buffer: Double? { customBuffer ? min(120, max(1, bufferSeconds)) : nil }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case appearance, showMenuBar, repeatMode, trackDoubleClickAction, doubleClickPlays, playingAutoSwitchMode, customBuffer, bufferSeconds, volume, localShortcuts, librarySortOrder, playlistAlbumGroups
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try values.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
        showMenuBar = try values.decodeIfPresent(Bool.self, forKey: .showMenuBar) ?? false
        repeatMode = try values.decodeIfPresent(RepeatMode.self, forKey: .repeatMode) ?? .none
        trackDoubleClickAction = try values.decodeIfPresent(TrackDoubleClickAction.self, forKey: .trackDoubleClickAction)
            ?? ((try values.decodeIfPresent(Bool.self, forKey: .doubleClickPlays) ?? false) ? .playNow : .append)
        playingAutoSwitchMode = (try? values.decodeIfPresent(String.self, forKey: .playingAutoSwitchMode))
            .flatMap(PlayingAutoSwitchMode.init(rawValue:)) ?? .manualTrackStart
        customBuffer = try values.decodeIfPresent(Bool.self, forKey: .customBuffer) ?? false
        bufferSeconds = try values.decodeIfPresent(Double.self, forKey: .bufferSeconds) ?? 20
        volume = try values.decodeIfPresent(Double.self, forKey: .volume) ?? 0.75
        localShortcuts = try values.decodeIfPresent([String: Data].self, forKey: .localShortcuts) ?? [:]
        librarySortOrder = (try? values.decodeIfPresent(LibrarySortOrder.self, forKey: .librarySortOrder)) ?? LibrarySortOrder()
        playlistAlbumGroups = (try? values.decodeIfPresent(Bool.self, forKey: .playlistAlbumGroups)) ?? false
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(appearance, forKey: .appearance)
        try values.encode(showMenuBar, forKey: .showMenuBar)
        try values.encode(repeatMode, forKey: .repeatMode)
        try values.encode(trackDoubleClickAction, forKey: .trackDoubleClickAction)
        try values.encode(playingAutoSwitchMode, forKey: .playingAutoSwitchMode)
        try values.encode(customBuffer, forKey: .customBuffer)
        try values.encode(bufferSeconds, forKey: .bufferSeconds)
        try values.encode(volume, forKey: .volume)
        try values.encode(localShortcuts, forKey: .localShortcuts)
        try values.encode(librarySortOrder, forKey: .librarySortOrder)
        try values.encode(playlistAlbumGroups, forKey: .playlistAlbumGroups)
    }

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "Macarok.preferences"), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "Macarok.preferences") } }
}

extension KeyboardShortcuts.Name {
    static let playPause = Self("playPause")
    static let nextTrack = Self("nextTrack")
    static let previousTrack = Self("previousTrack")
    static let showMacarok = Self("showMacarok")
}

extension Double {
    var playbackTime: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let value = Int(self)
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
}
