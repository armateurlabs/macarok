import Foundation
import CryptoKit

public struct OpenSubsonicError: LocalizedError, Sendable {
    public let code: Int
    public let message: String
    public init(code: Int, message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

private actor RemoteLibraryCollection {
    private var tracks: [RemoteTrack] = []
    private var completed = 0
    private var reportedTotal = false

    func append(_ batch: [RemoteTrack], completed: Int, total: Int?) {
        tracks.append(contentsOf: batch)
        self.completed = completed
        reportedTotal = total != nil
    }

    func result() -> (tracks: [RemoteTrack], completed: Int, reportedTotal: Bool) {
        (tracks, completed, reportedTotal)
    }
}

public struct RemoteArtist: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var albumCount: Int
}

public struct RemoteAlbum: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var artist: String
    public var artistID: String?
    public var year: Int?
    public var coverArtID: String?
    public var songCount: Int
}

public struct RemoteTrack: Identifiable, Sendable, Equatable {
    public var id: String
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
    public var format: String
    public var path: String?
    public var coverArtID: String?
    public var bitRate: Int?

    public func asTrackRecord(sourceID: String, artworkPath: String? = nil) -> TrackRecord {
        TrackRecord(id: StableID.make(sourceID, "opensubsonic", id), sourceID: sourceID,
                    albumID: StableID.make(sourceID, "opensubsonic-album", albumID),
                    title: title, artist: artist, albumArtist: albumArtist, album: album,
                    year: year, genre: genre, trackNumber: trackNumber, discNumber: discNumber,
                    duration: duration, remoteID: id, remotePath: path, coverArtID: coverArtID,
                    format: format, artworkPath: artworkPath)
    }
}

public struct RemoteFolder: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
}

public struct RemoteDirectoryEntry: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var isDirectory: Bool
    public var parentID: String?
    public var track: RemoteTrack?
}

public struct OpenSubsonicServerInfo: Sendable, Equatable {
    public var version: String
    public var serverType: String?
    public var serverVersion: String?
    public var isOpenSubsonic: Bool
}

public struct OpenSubsonicClient: Sendable {
    public let baseURL: URL
    public let credentials: SourceCredentials
    public let transport: SourceTransport
    private let protocolVersion = "1.16.1"

    public init(baseURL: URL, credentials: SourceCredentials, transport: SourceTransport) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.transport = transport
    }

    public func endpointURL(_ endpoint: String, parameters: [String: String] = [:], salt: String? = nil) throws -> URL {
        guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil,
              baseURL.fragment == nil else { throw SourceNetworkError.invalidURL }
        let path = baseURL.appendingPathComponent("rest").appendingPathComponent(endpoint + ".view")
        guard var components = URLComponents(url: path, resolvingAgainstBaseURL: false) else { throw SourceNetworkError.invalidURL }
        var values = parameters
        values["v"] = protocolVersion
        values["c"] = "Macarok"
        values["f"] = "json"
        if let apiKey = credentials.apiKey, !apiKey.isEmpty {
            values["apiKey"] = apiKey
        } else {
            guard !credentials.username.isEmpty else { throw SourceNetworkError.missingCredentials }
            let salt = salt ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let hash = Insecure.MD5.hash(data: Data((credentials.password + salt).utf8))
            values["u"] = credentials.username
            values["s"] = salt
            values["t"] = hash.map { String(format: "%02x", $0) }.joined()
        }
        components.queryItems = values.keys.sorted().map { URLQueryItem(name: $0, value: values[$0]) }
        components.fragment = nil
        guard let url = components.url else { throw SourceNetworkError.invalidURL }
        return url
    }

    public func ping() async throws -> OpenSubsonicServerInfo {
        let response = try await request("ping")
        return .init(version: response["version"] as? String ?? "", serverType: response["type"] as? String,
                     serverVersion: response["serverVersion"] as? String, isOpenSubsonic: response["openSubsonic"] as? Bool ?? false)
    }

    public func extensions() async throws -> [String] {
        let response = try await request("getOpenSubsonicExtensions")
        return (response["openSubsonicExtensions"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    public func artists() async throws -> [RemoteArtist] {
        let response = try await request("getArtists")
        let container = response["artists"] as? [String: Any] ?? [:]
        return (container["index"] as? [[String: Any]] ?? []).flatMap { index in
            (index["artist"] as? [[String: Any]] ?? []).compactMap { value in
                guard let id = string(value["id"]), let name = string(value["name"]) else { return nil }
                return RemoteArtist(id: id, name: name, albumCount: integer(value["albumCount"]) ?? 0)
            }
        }
    }

    public func albums(artistID: String) async throws -> [RemoteAlbum] {
        let response = try await request("getArtist", parameters: ["id": artistID])
        let artist = response["artist"] as? [String: Any] ?? [:]
        return (artist["album"] as? [[String: Any]] ?? []).compactMap(parseAlbum)
    }

    public func albums(offset: Int = 0, size: Int = 500, type: String = "alphabeticalByName") async throws -> [RemoteAlbum] {
        let response = try await request("getAlbumList2", parameters: ["type": type, "size": String(min(max(1, size), 500)), "offset": String(max(0, offset))])
        guard let list = response["albumList2"] as? [String: Any] else { throw SourceNetworkError.invalidResponse }
        guard let entries = list["album"] else { return [] }
        guard let values = entries as? [[String: Any]] else { throw SourceNetworkError.invalidResponse }
        return try values.map { value in
            guard let album = parseAlbum(value) else { throw SourceNetworkError.invalidResponse }
            return album
        }
    }

    public func songs(albumID: String) async throws -> [RemoteTrack] {
        let response = try await request("getAlbum", parameters: ["id": albumID])
        guard let album = response["album"] as? [String: Any] else { throw SourceNetworkError.invalidResponse }
        guard let entries = album["song"] else { return [] }
        guard let values = entries as? [[String: Any]] else { throw SourceNetworkError.invalidResponse }
        return try values.map { value in
            guard let track = parseTrack(value, fallbackAlbum: album) else { throw SourceNetworkError.invalidResponse }
            return track
        }
    }

    public func fetchLibrary(sourceID: String, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [RemoteTrack] {
        let collection = RemoteLibraryCollection()
        try await streamLibrary(sourceID: sourceID) { tracks, completed, total in
            await collection.append(tracks, completed: completed, total: total)
            // The legacy callback cannot represent an unknown total. Report only known totals.
            if let total { progress?(completed, total) }
        }
        let result = await collection.result()
        if !result.reportedTotal { progress?(result.completed, result.completed) }
        return result.tracks
    }

    /// Publishes each completed album before requesting the next album or catalog page.
    /// The consumer is awaited so it can persist a batch before further network work begins.
    /// The total remains unknown until a short catalog page establishes the end of the list.
    public func streamLibrary(sourceID: String,
                              receiveBatch: @escaping @Sendable ([RemoteTrack], Int, Int?) async throws -> Void) async throws {
        var seen = Set<String>()
        var offset = 0
        var completed = 0
        while true {
            try Task.checkCancellation()
            let page = try await albums(offset: offset)
            try Task.checkCancellation()
            let new = page.filter { seen.insert($0.id).inserted }
            let isFinalPage = page.count < 500
            // A server that ignores offset must not turn a partial import into a complete snapshot.
            guard isFinalPage || !new.isEmpty else { throw SourceNetworkError.invalidResponse }
            let total: Int? = isFinalPage ? seen.count : nil
            for album in new {
                try Task.checkCancellation()
                let tracks = try await songs(albumID: album.id)
                try Task.checkCancellation()
                completed += 1
                try await receiveBatch(tracks, completed, total)
                try Task.checkCancellation()
            }
            if isFinalPage { return }
            offset += page.count
        }
    }

    public func search(_ query: String, count: Int = 100) async throws -> [RemoteTrack] {
        let response = try await request("search3", parameters: ["query": query, "songCount": String(max(1, min(count, 500))), "albumCount": "0", "artistCount": "0"])
        let result = response["searchResult3"] as? [String: Any] ?? [:]
        return (result["song"] as? [[String: Any]] ?? []).compactMap { parseTrack($0) }
    }

    public func folders() async throws -> [RemoteFolder] {
        let response = try await request("getMusicFolders")
        let folders = response["musicFolders"] as? [String: Any] ?? [:]
        return (folders["musicFolder"] as? [[String: Any]] ?? []).compactMap { value in
            guard let id = string(value["id"]) else { return nil }
            return RemoteFolder(id: id, name: string(value["name"]) ?? "Music")
        }
    }

    public func directory(id: String) async throws -> [RemoteDirectoryEntry] {
        let response = try await request("getMusicDirectory", parameters: ["id": id])
        let directory = response["directory"] as? [String: Any] ?? [:]
        return (directory["child"] as? [[String: Any]] ?? []).compactMap { value in
            guard let childID = string(value["id"]) else { return nil }
            let isDirectory = value["isDir"] as? Bool ?? false
            return .init(id: childID, title: string(value["title"]) ?? string(value["name"]) ?? "Untitled",
                         isDirectory: isDirectory, parentID: string(value["parent"]) ?? id,
                         track: isDirectory ? nil : parseTrack(value))
        }
    }

    public func lyrics(songID: String) async throws -> String? {
        try await structuredLyrics(songID: songID).first?.plainText
    }

    public func structuredLyrics(songID: String) async throws -> [LyricsDocument] {
        let response = try await request("getLyricsBySongId", parameters: ["id": songID])
        guard let rawList = response["lyricsList"] else { return [] }
        guard let list = rawList as? [String: Any] else { throw SourceNetworkError.invalidResponse }
        guard let rawLyrics = list["structuredLyrics"] else { return [] }
        guard let lyrics = rawLyrics as? [[String: Any]] else { throw SourceNetworkError.invalidResponse }
        return try lyrics.enumerated().compactMap { index, entry in
            guard let rawRows = entry["line"] else { return nil }
            guard let rows = rawRows as? [[String: Any]], rows.allSatisfy({ $0["value"] is String }) else {
                throw SourceNetworkError.invalidResponse
            }
            let plain = rows.compactMap { $0["value"] as? String }.joined(separator: "\n")
            let rawOffset = (entry["offset"] as? NSNumber)?.doubleValue ?? Double(entry["offset"] as? String ?? "") ?? 0
            let offset = rawOffset.isFinite ? rawOffset / 1_000 : 0
            let timed: [LyricsLine] = try rows.enumerated().compactMap { lineIndex, row in
                guard entry["synced"] as? Bool == true, let text = row["value"] as? String,
                      let start = row["start"] else { return nil }
                guard let milliseconds = (start as? NSNumber)?.doubleValue ?? Double(start as? String ?? ""),
                      milliseconds.isFinite else { throw SourceNetworkError.invalidResponse }
                return LyricsLine(id: StableID.make(songID, String(index), String(lineIndex)),
                                  startTime: milliseconds / 1_000 - offset, text: text)
            }
            let document = LyricsDocument(plainText: plain, lines: timed.count == rows.count ? timed : [],
                                          source: .openSubsonic, providerID: songID)
            return document.hasContent ? document : nil
        }
    }

    public func lyrics(artist: String, title: String) async throws -> String? {
        let response = try await request("getLyrics", parameters: ["artist": artist, "title": title])
        let lyrics = response["lyrics"] as? [String: Any] ?? [:]
        return string(lyrics["value"])
    }

    public func streamURL(songID: String) throws -> URL {
        try endpointURL("stream", parameters: ["id": songID, "format": "raw", "maxBitRate": "0"])
    }

    public func coverArtURL(id: String, size: Int? = nil) throws -> URL {
        var parameters = ["id": id]
        if let size { parameters["size"] = String(size) }
        return try endpointURL("getCoverArt", parameters: parameters)
    }

    public func coverArt(id: String, size: Int? = nil) async throws -> Data {
        try await transport.data(from: coverArtURL(id: id, size: size))
    }

    public func scrobble(songID: String, submission: Bool = true, date: Date = Date()) async throws {
        _ = try await request("scrobble", parameters: ["id": songID, "submission": String(submission), "time": String(Int64(date.timeIntervalSince1970 * 1000))])
    }

    private func request(_ endpoint: String, parameters: [String: String] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: try endpointURL(endpoint, parameters: parameters))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await transport.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let root = json as? [String: Any], let response = root["subsonic-response"] as? [String: Any] else {
            throw SourceNetworkError.invalidResponse
        }
        if response["status"] as? String == "failed" {
            let error = response["error"] as? [String: Any] ?? [:]
            throw OpenSubsonicError(code: integer(error["code"]) ?? 0,
                                   message: string(error["message"]) ?? "The music server rejected the request.")
        }
        guard response["status"] as? String == "ok" else { throw SourceNetworkError.invalidResponse }
        return response
    }

    private func parseAlbum(_ value: [String: Any]) -> RemoteAlbum? {
        guard let id = string(value["id"]) else { return nil }
        return .init(id: id, title: string(value["name"]) ?? string(value["title"]) ?? "Unknown Album",
                     artist: string(value["artist"]) ?? "Unknown Artist", artistID: string(value["artistId"]),
                     year: integer(value["year"]), coverArtID: string(value["coverArt"]), songCount: integer(value["songCount"]) ?? 0)
    }

    private func parseTrack(_ value: [String: Any], fallbackAlbum: [String: Any] = [:]) -> RemoteTrack? {
        guard let id = string(value["id"]), value["isDir"] as? Bool != true else { return nil }
        let artist = string(value["artist"]) ?? string(fallbackAlbum["artist"]) ?? "Unknown Artist"
        let artists = value["albumArtists"] as? [[String: Any]]
        let albumArtist = string(value["albumArtist"]) ?? artists?.compactMap { string($0["name"]) }.joined(separator: "; ") ?? string(fallbackAlbum["artist"]) ?? artist
        return .init(id: id, albumID: string(value["albumId"]) ?? string(fallbackAlbum["id"]) ?? "unknown",
                     title: string(value["title"]) ?? "Unknown Title", artist: artist, albumArtist: albumArtist,
                     album: string(value["album"]) ?? string(fallbackAlbum["name"]) ?? "Unknown Album",
                     year: integer(value["year"]) ?? integer(fallbackAlbum["year"]), genre: string(value["genre"]),
                     trackNumber: integer(value["track"]), discNumber: integer(value["discNumber"]),
                     duration: (value["duration"] as? NSNumber)?.doubleValue ?? 0,
                     format: (string(value["suffix"]) ?? "audio").uppercased(), path: string(value["path"]),
                     coverArtID: string(value["coverArt"]) ?? string(fallbackAlbum["coverArt"]), bitRate: integer(value["bitRate"]))
    }

    private func string(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
