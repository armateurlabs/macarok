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

struct AppPreferences: Codable {
    var appearance: Appearance = .system
    var repeatMode: RepeatMode = .none
    var doubleClickPlays = false
    var customBuffer = false
    var bufferSeconds: Double = 20
    var volume: Double = 0.75
    var localShortcuts: [String: Data] = [:]
    var buffer: Double? { customBuffer ? min(120, max(1, bufferSeconds)) : nil }

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
