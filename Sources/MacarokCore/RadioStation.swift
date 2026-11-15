import Foundation

public enum RadioLibrary {
    public static let sourceID = "macarok-internet-radio"
    public static var source: SourceRecord { SourceRecord(id: sourceID, kind: .radio, name: "Internet Radio", location: "") }
}

public struct RadioStationRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sourceID: String
    public var name: String
    public var streamURL: String
    public var resolvedURL: String?
    public var directoryID: String?
    public var homepage: String?
    public var artworkURL: String?
    public var country: String
    public var language: String
    public var tags: String
    public var codec: String
    public var bitrate: Int
    public var isFavorite: Bool
    public var isHLS: Bool

    public init(id: String? = nil, sourceID: String = RadioLibrary.sourceID, name: String, streamURL: String,
                resolvedURL: String? = nil, directoryID: String? = nil, homepage: String? = nil,
                artworkURL: String? = nil, country: String = "", language: String = "", tags: String = "",
                codec: String = "", bitrate: Int = 0, isFavorite: Bool = false, isHLS: Bool = false) {
        self.id = id ?? StableID.make(sourceID, "radio", directoryID ?? streamURL)
        self.sourceID = sourceID; self.name = name; self.streamURL = streamURL; self.resolvedURL = resolvedURL
        self.directoryID = directoryID; self.homepage = homepage; self.artworkURL = artworkURL
        self.country = country; self.language = language; self.tags = tags; self.codec = codec
        self.bitrate = max(0, bitrate); self.isFavorite = isFavorite; self.isHLS = isHLS
    }
    public var title: String { name }
    public var description: String {
        [country, language, codec, bitrate > 0 ? "\(bitrate) kbps" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    public var track: TrackRecord {
        TrackRecord(id: id, sourceID: sourceID, albumID: StableID.make(sourceID, "stations"), title: name,
                    artist: "", albumArtist: "", album: "", genre: tags.isEmpty ? nil : tags,
                    duration: 0, fileURL: streamURL, remoteID: directoryID, format: codec.isEmpty ? "RADIO" : codec)
    }
}

public enum RadioError: LocalizedError, Sendable {
    case invalidURL, invalidResponse, unsupportedHLS, playlistLoop, emptyPlaylist
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid HTTP or HTTPS radio stream URL without embedded credentials."
        case .invalidResponse: "The radio service returned an invalid response."
        case .unsupportedHLS: "HLS radio streams are not supported yet. Choose a direct MP3, AAC, Ogg, or Opus stream."
        case .playlistLoop: "The radio playlist contains too many nested playlists."
        case .emptyPlaylist: "The playlist contains no supported radio stream."
        }
    }
    public static func validatedURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { throw RadioError.invalidURL }
        return url
    }
}
