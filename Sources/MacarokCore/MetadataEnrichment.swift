import Foundation

public struct MusicBrainzRelease: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var artist: String
    public var date: String?
    public var country: String?
    public var disambiguation: String?
    public var trackCount: Int
    public var score: Int?
    public var year: Int? { date.flatMap { Int($0.prefix(4)) } }
}

public struct MusicBrainzTrack: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var artist: String
    public var recordingID: String?
    public var position: Int
    public var discNumber: Int
    public var duration: Double?
}

public struct MusicBrainzReleaseDetail: Sendable, Equatable {
    public var release: MusicBrainzRelease
    public var tracks: [MusicBrainzTrack]
}

public struct CoverArtwork: Identifiable, Sendable, Equatable {
    public var id: String
    public var imageURL: URL
    public var thumbnailURL: URL?
    public var isFront: Bool
    public var types: [String]
    public var comment: String
}

public struct MetadataChange: Identifiable, Sendable, Equatable {
    public var field: String
    public var currentValue: String
    public var proposedValue: String
    public var id: String { field }

    public init(field: String, currentValue: String, proposedValue: String) {
        self.field = field
        self.currentValue = currentValue
        self.proposedValue = proposedValue
    }
}

public struct MetadataProposal: Sendable, Equatable {
    public var trackID: String
    public var releaseID: String?
    public var changes: [MetadataChange]

    public init(trackID: String, releaseID: String? = nil, changes: [MetadataChange]) {
        self.trackID = trackID; self.releaseID = releaseID; self.changes = changes
    }

    public func applying(to track: TrackRecord, fields: Set<String>? = nil) -> TrackRecord {
        var result = track
        for change in changes where fields?.contains(change.field) != false {
            switch change.field {
            case "title": result.title = change.proposedValue
            case "artist": result.artist = change.proposedValue
            case "albumArtist": result.albumArtist = change.proposedValue
            case "album": result.album = change.proposedValue
            case "genre": result.genre = change.proposedValue.isEmpty ? nil : change.proposedValue
            case "year": result.year = Int(change.proposedValue)
            case "trackNumber": result.trackNumber = Int(change.proposedValue)
            case "discNumber": result.discNumber = Int(change.proposedValue)
            default: break
            }
        }
        return result
    }
}

public enum MetadataCleanup {
    public static func proposal(for track: TrackRecord) -> MetadataProposal {
        let values = [("title", track.title), ("artist", track.artist), ("albumArtist", track.albumArtist),
                      ("album", track.album), ("genre", track.genre ?? "")]
        let changes = values.compactMap { field, value -> MetadataChange? in
            let cleaned = value.precomposedStringWithCanonicalMapping
                .replacingOccurrences(of: "[\\t\\r\\n ]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned == value ? nil : .init(field: field, currentValue: value, proposedValue: cleaned)
        }
        return .init(trackID: track.id, changes: changes)
    }
}

public enum MetadataServiceError: LocalizedError, Sendable {
    case missingQuery
    case invalidReleaseID
    public var errorDescription: String? {
        switch self {
        case .missingQuery: return "Enter an artist or album name to find metadata."
        case .invalidReleaseID: return "The MusicBrainz release identifier is invalid."
        }
    }
}

public actor MusicBrainzClient {
    public let transport: SourceTransport
    private var nextRequestDate = Date.distantPast
    private var cache: [URL: Data] = [:]
    private let userAgent = "Macarok/0.1.0 (https://github.com/armateurlabs/macarok)"

    public init(transport: SourceTransport = SourceTransport(sourceID: "metadata.musicbrainz")) {
        self.transport = transport
    }

    public func searchReleases(artist: String, album: String, limit: Int = 8) async throws -> [MusicBrainzRelease] {
        var terms: [String] = []
        if !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { terms.append("artist:\"\(escaped(artist))\"") }
        if !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { terms.append("release:\"\(escaped(album))\"") }
        guard !terms.isEmpty else { throw MetadataServiceError.missingQuery }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        components.queryItems = [.init(name: "query", value: terms.joined(separator: " AND ")),
                                 .init(name: "fmt", value: "json"), .init(name: "limit", value: String(min(max(1, limit), 25)))]
        let json = try await json(from: components.url!, rateLimited: true)
        return (json["releases"] as? [[String: Any]] ?? []).compactMap(parseRelease)
    }

    public func release(id: String) async throws -> MusicBrainzReleaseDetail {
        guard UUID(uuidString: id) != nil else { throw MetadataServiceError.invalidReleaseID }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/\(id)")!
        components.queryItems = [.init(name: "inc", value: "recordings+artist-credits+release-groups"), .init(name: "fmt", value: "json")]
        let json = try await json(from: components.url!, rateLimited: true)
        guard let release = parseRelease(json) else { throw SourceNetworkError.invalidResponse }
        var tracks: [MusicBrainzTrack] = []
        for (discIndex, medium) in (json["media"] as? [[String: Any]] ?? []).enumerated() {
            let discNumber = (medium["position"] as? Int) ?? discIndex + 1
            for (trackIndex, track) in (medium["tracks"] as? [[String: Any]] ?? []).enumerated() {
                let recording = track["recording"] as? [String: Any] ?? [:]
                let id = track["id"] as? String ?? recording["id"] as? String ?? "\(discNumber):\(trackIndex)"
                let trackArtist = artistCredit(track["artist-credit"] as? [[String: Any]] ?? [])
                let recordingArtist = artistCredit(recording["artist-credit"] as? [[String: Any]] ?? [])
                tracks.append(.init(id: id, title: track["title"] as? String ?? recording["title"] as? String ?? "Unknown Track",
                    artist: !trackArtist.isEmpty ? trackArtist : !recordingArtist.isEmpty ? recordingArtist : release.artist,
                    recordingID: recording["id"] as? String, position: track["position"] as? Int ?? trackIndex + 1,
                    discNumber: discNumber, duration: ((track["length"] ?? recording["length"]) as? NSNumber).map { $0.doubleValue / 1000 }))
            }
        }
        return .init(release: release, tracks: tracks)
    }

    public func artwork(forReleaseID id: String) async throws -> [CoverArtwork] {
        guard UUID(uuidString: id) != nil else { throw MetadataServiceError.invalidReleaseID }
        let url = URL(string: "https://coverartarchive.org/release/\(id)")!
        let payload: [String: Any]
        do { payload = try await json(from: url, rateLimited: false) }
        catch SourceNetworkError.httpStatus(404) { return [] }
        return (payload["images"] as? [[String: Any]] ?? []).compactMap { value in
            guard let string = value["image"] as? String, let image = URL(string: string),
                  ["https", "http"].contains(image.scheme?.lowercased() ?? "") else { return nil }
            let thumbnails = value["thumbnails"] as? [String: String] ?? [:]
            return CoverArtwork(id: (value["id"] as? String) ?? (value["id"] as? NSNumber)?.stringValue ?? string,
                imageURL: image, thumbnailURL: (thumbnails["500"] ?? thumbnails["small"]).flatMap(URL.init(string:)),
                isFront: value["front"] as? Bool ?? false, types: value["types"] as? [String] ?? [], comment: value["comment"] as? String ?? "")
        }.sorted { $0.isFront && !$1.isFront }
    }

    public func imageData(for artwork: CoverArtwork, thumbnail: Bool = false) async throws -> Data {
        var request = URLRequest(url: thumbnail ? artwork.thumbnailURL ?? artwork.imageURL : artwork.imageURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return try await transport.data(for: request).0
    }

    public nonisolated func proposal(for track: TrackRecord, release detail: MusicBrainzReleaseDetail) -> MetadataProposal {
        let matched = detail.tracks.first { $0.position == track.trackNumber && $0.discNumber == (track.discNumber ?? 1) }
            ?? detail.tracks.first { $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == track.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        var fields = [("album", track.album, detail.release.title), ("albumArtist", track.albumArtist, detail.release.artist)]
        if let year = detail.release.year { fields.append(("year", track.year.map(String.init) ?? "", String(year))) }
        if let matched {
            fields.append(("title", track.title, matched.title))
            fields.append(("artist", track.artist, matched.artist))
            fields.append(("trackNumber", track.trackNumber.map(String.init) ?? "", String(matched.position)))
            fields.append(("discNumber", track.discNumber.map(String.init) ?? "", String(matched.discNumber)))
        }
        return .init(trackID: track.id, releaseID: detail.release.id,
                     changes: fields.compactMap { field, current, proposed in current == proposed ? nil : .init(field: field, currentValue: current, proposedValue: proposed) })
    }

    private func json(from url: URL, rateLimited: Bool) async throws -> [String: Any] {
        let data: Data
        if let cached = cache[url] { data = cached }
        else {
            if rateLimited {
                let scheduled = max(Date(), nextRequestDate)
                nextRequestDate = scheduled.addingTimeInterval(1.05)
                let delay = scheduled.timeIntervalSinceNow
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            }
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            data = try await transport.data(for: request).0
            cache[url] = data
        }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SourceNetworkError.invalidResponse }
        return value
    }

    private func parseRelease(_ value: [String: Any]) -> MusicBrainzRelease? {
        guard let id = value["id"] as? String, let title = value["title"] as? String else { return nil }
        let media = value["media"] as? [[String: Any]] ?? []
        return .init(id: id, title: title, artist: artistCredit(value["artist-credit"] as? [[String: Any]] ?? []),
                     date: value["date"] as? String, country: value["country"] as? String,
                     disambiguation: value["disambiguation"] as? String,
                     trackCount: value["track-count"] as? Int ?? media.reduce(0) { $0 + ($1["track-count"] as? Int ?? 0) },
                     score: value["score"] as? Int ?? (value["score"] as? String).flatMap(Int.init))
    }

    private func artistCredit(_ credits: [[String: Any]]) -> String {
        credits.map { credit in
            let artist = credit["artist"] as? [String: Any] ?? [:]
            return (credit["name"] as? String ?? artist["name"] as? String ?? "") + (credit["joinphrase"] as? String ?? "")
        }.joined()
    }

    private func escaped(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
