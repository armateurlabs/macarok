import CryptoKit
import Foundation
import GRDB

public enum SourceKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case local
    case openSubsonic
    case podcasts
    case radio

    public var displayName: String {
        switch self {
        case .local: "Local Files"
        case .openSubsonic: "OpenSubsonic"
        case .podcasts: "Podcasts"
        case .radio: "Internet Radio"
        }
    }
}

public struct SourceRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Hashable {
    public static let databaseTableName = "sources"
    public var id: String
    public var kind: SourceKind
    public var name: String
    public var location: String
    public var createdAt: Date
    public var bookmarkData: Data?

    public init(id: String = UUID().uuidString, kind: SourceKind, name: String, location: String,
                createdAt: Date = Date(), bookmarkData: Data? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.location = location
        self.createdAt = createdAt
        self.bookmarkData = bookmarkData
    }

    public var url: URL? {
        if let url = URL(string: location), url.scheme != nil { return url }
        return kind == .local ? URL(fileURLWithPath: location) : nil
    }
}

public struct TrackRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Hashable {
    public static let databaseTableName = "tracks"
    public var id: String
    public var sourceID: String
    public var albumID: String
    public var title: String
    public var artist: String
    public var albumArtist: String
    public var album: String
    public var year: Int?
    public var genre: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: Double
    public var fileURL: String?
    public var remoteID: String?
    public var remotePath: String?
    public var coverArtID: String?
    public var format: String
    public var artworkPath: String?
    public var cuePath: String?
    public var startTime: Double?
    public var endTime: Double?
    public var addedAt: Date
    public var lastPlayedAt: Date?
    public var playCount: Int
    public var rating: Int
    public var isAvailable: Bool
    public var metadataLocked: Bool

    public init(id: String = UUID().uuidString, sourceID: String, albumID: String = "",
                title: String = "Unknown Track", artist: String = "Unknown Artist",
                albumArtist: String = "", album: String = "Unknown Album", year: Int? = nil,
                genre: String? = nil, trackNumber: Int? = nil, discNumber: Int? = nil,
                duration: Double = 0, fileURL: String? = nil, remoteID: String? = nil,
                remotePath: String? = nil, coverArtID: String? = nil,
                format: String = "", artworkPath: String? = nil, cuePath: String? = nil,
                startTime: Double? = nil, endTime: Double? = nil, addedAt: Date = Date(),
                lastPlayedAt: Date? = nil, playCount: Int = 0, rating: Int = 0,
                isAvailable: Bool = true, metadataLocked: Bool = false) {
        self.id = id
        self.sourceID = sourceID
        self.albumID = albumID.isEmpty ? StableID.make(sourceID, albumArtist.isEmpty ? artist : albumArtist, album) : albumID
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist.isEmpty ? artist : albumArtist
        self.album = album
        self.year = year
        self.genre = genre
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.fileURL = fileURL
        self.remoteID = remoteID
        self.remotePath = remotePath
        self.coverArtID = coverArtID
        self.format = format
        self.artworkPath = artworkPath
        self.cuePath = cuePath
        self.startTime = startTime
        self.endTime = endTime
        self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt
        self.playCount = max(0, playCount)
        self.rating = min(5, max(0, rating))
        self.isAvailable = isAvailable
        self.metadataLocked = metadataLocked
    }

    public var url: URL? {
        guard let fileURL else { return nil }
        if let url = URL(string: fileURL), url.scheme != nil { return url }
        return URL(fileURLWithPath: fileURL)
    }

    public var isCUETrack: Bool { cuePath != nil || startTime != nil }
    public var displayArtist: String { artist.isEmpty ? "Unknown Artist" : artist }
    public var displayAlbum: String { album.isEmpty ? "Unknown Album" : album }
    public var formattedDuration: String {
        let value = Int(duration.isFinite ? max(0, duration) : 0)
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}

public struct AlbumRecord: Identifiable, Sendable, Hashable {
    public var id: String
    public var sourceID: String
    public var title: String
    public var artist: String
    public var year: Int?
    public var genre: String?
    public var artworkPath: String?
    public var tracks: [TrackRecord]
    public var playCount: Int
    public var lastPlayedAt: Date?
    public var addedAt: Date

    public init(tracks: [TrackRecord]) {
        self.init(orderedTracks: tracks.sorted(by: TrackRecord.libraryOrder))
    }

    /// Reuses tracks already ordered by `TrackRecord.libraryOrder`.
    public init(orderedTracks ordered: [TrackRecord]) {
        let first = ordered.first
        self.id = first?.albumID ?? UUID().uuidString
        self.sourceID = first?.sourceID ?? ""
        self.title = first?.album ?? "Unknown Album"
        self.artist = first?.albumArtist ?? "Unknown Artist"
        self.year = ordered.compactMap(\.year).first
        self.genre = ordered.compactMap(\.genre).first
        self.artworkPath = ordered.compactMap(\.artworkPath).first
        self.tracks = ordered
        self.playCount = ordered.reduce(0) { $0 + $1.playCount }
        self.lastPlayedAt = ordered.compactMap(\.lastPlayedAt).max()
        self.addedAt = ordered.map(\.addedAt).min() ?? Date()
    }

    public var duration: Double { tracks.reduce(0) { $0 + $1.duration } }
    public var name: String { title }
}

public struct ArtistSummary: Identifiable, Sendable, Hashable {
    public var id: String
    public var sourceID: String
    public var name: String
    public var albums: [AlbumRecord]
    public var trackCount: Int
    public var playCount: Int
    public var artworkPath: String?

    public init(name: String, sourceID: String, tracks: [TrackRecord]) {
        self.id = StableID.make(sourceID, name)
        self.sourceID = sourceID
        self.name = name
        self.albums = Dictionary(grouping: tracks, by: \.albumID).values.map { AlbumRecord(tracks: $0) }
            .sorted { ($0.year ?? 0, $0.title) < ($1.year ?? 0, $1.title) }
        self.trackCount = tracks.count
        self.playCount = tracks.reduce(0) { $0 + $1.playCount }
        self.artworkPath = tracks.compactMap(\.artworkPath).first
    }

    /// Reuses the canonical album records prepared for a library snapshot.
    public init(name: String, sourceID: String, albums: [AlbumRecord]) {
        self.id = StableID.make(sourceID, name)
        self.sourceID = sourceID
        self.name = name
        self.albums = albums.sorted {
            let leftYear = $0.year ?? 0
            let rightYear = $1.year ?? 0
            if leftYear != rightYear { return leftYear < rightYear }
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return $0.id < $1.id
        }
        self.trackCount = albums.reduce(0) { $0 + $1.tracks.count }
        self.playCount = albums.reduce(0) { $0 + $1.playCount }
        self.artworkPath = self.albums.lazy.compactMap(\.artworkPath).first
    }
}

public struct PlaylistRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Hashable {
    public static let databaseTableName = "playlists"
    public var id: String
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PlaybackQueueSnapshot: Codable, Sendable, Equatable {
    public var trackIDs: [String]
    public var currentIndex: Int
    public var position: Double

    public init(trackIDs: [String], currentIndex: Int = 0, position: Double = 0) {
        self.trackIDs = trackIDs
        self.currentIndex = trackIDs.isEmpty ? 0 : min(max(0, currentIndex), trackIDs.count - 1)
        self.position = position.isFinite ? max(0, position) : 0
    }
}

public struct AudioFileMetadata: Codable, Sendable {
    public var title: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var year: Int?
    public var genre: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: Double?
    public var format: String?
    public var artworkData: Data?
    public var artworkMIMEType: String?
    public var artworkPath: String?
    public var embeddedCueSheet: String?
    public var sampleRate: Int?
    public var channels: Int?
    public var bitsPerSample: Int?
    public var cuePoints: [AudioCuePoint]?

    public init(title: String? = nil, artist: String? = nil, albumArtist: String? = nil,
                album: String? = nil, year: Int? = nil, genre: String? = nil,
                trackNumber: Int? = nil, discNumber: Int? = nil, duration: Double? = nil,
                format: String? = nil, artworkData: Data? = nil, artworkMIMEType: String? = nil,
                artworkPath: String? = nil, embeddedCueSheet: String? = nil,
                sampleRate: Int? = nil, channels: Int? = nil, bitsPerSample: Int? = nil,
                cuePoints: [AudioCuePoint]? = nil) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.year = year
        self.genre = genre
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.format = format
        self.artworkData = artworkData
        self.artworkMIMEType = artworkMIMEType
        self.artworkPath = artworkPath
        self.embeddedCueSheet = embeddedCueSheet
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.cuePoints = cuePoints
    }
}

public struct AudioCuePoint: Codable, Sendable, Equatable {
    public var number: Int
    public var startSample: Int64
    public var endSample: Int64?
    public var sampleRate: Int
    public var title: String?

    public var artist: String?

    public init(number: Int, startSample: Int64, endSample: Int64? = nil, sampleRate: Int, title: String? = nil, artist: String? = nil) {
        self.number = number
        self.startSample = startSample
        self.endSample = endSample
        self.sampleRate = sampleRate
        self.title = title
        self.artist = artist
    }
}

public enum StableID {
    public static func make(_ parts: String...) -> String { make(parts: parts) }
    public static func make(parts: [String]) -> String {
        let data = parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|").data(using: .utf8)!
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension TrackRecord {
    public static func libraryOrder(_ lhs: TrackRecord, _ rhs: TrackRecord) -> Bool {
        let artistOrder = lhs.albumArtist.localizedStandardCompare(rhs.albumArtist)
        if artistOrder != .orderedSame { return artistOrder == .orderedAscending }
        let albumOrder = lhs.album.localizedStandardCompare(rhs.album)
        if albumOrder != .orderedSame { return albumOrder == .orderedAscending }
        let leftDisc = lhs.discNumber ?? 1
        let rightDisc = rhs.discNumber ?? 1
        if leftDisc != rightDisc { return leftDisc < rightDisc }
        let leftTrack = lhs.trackNumber ?? 0
        let rightTrack = rhs.trackNumber ?? 0
        if leftTrack != rightTrack { return leftTrack < rightTrack }
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        return titleOrder == .orderedSame ? lhs.id < rhs.id : titleOrder == .orderedAscending
    }
}
