import Foundation
import GRDB
import Security

/// A song independent of its source: the same recording in two libraries shares its YouTube and Wikipedia links.
public struct SongKey: Hashable, Sendable {
    public let artist: String
    public let title: String
    public let id: String

    public init?(artist: String, title: String) {
        let artist = Self.primaryArtist(Self.collapsed(artist)), title = Self.cleanTitle(Self.collapsed(title))
        guard !artist.isEmpty, !title.isEmpty,
              !["unknown artist", "various artists"].contains(artist.lowercased()),
              !["unknown track", "unknown title"].contains(title.lowercased()) else { return nil }
        self.artist = artist; self.title = title
        id = Self.folded(artist) + "\u{1F}" + Self.folded(title)
    }

    public init?(track: TrackRecord) { self.init(artist: track.artist, title: track.title) }

    static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
    }

    static func collapsed(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// "Artist feat. Guest" is filed under the main artist on YouTube and Wikipedia.
    static func primaryArtist(_ value: String) -> String {
        let lowered = value.lowercased()
        let markers = [" feat. ", " feat ", " ft. ", " featuring ", " with "]
        let cut = markers.compactMap { lowered.range(of: $0)?.lowerBound }.min()
        guard let cut else { return value }
        return String(value[..<value.index(value.startIndex, offsetBy: lowered.distance(from: lowered.startIndex, to: cut))])
            .trimmingCharacters(in: .whitespaces)
    }

    /// Edition details are not part of the song: "Song (Remastered 2011)" and "Song - Radio Edit" are "Song".
    static func cleanTitle(_ value: String) -> String {
        var title = value.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        if let dash = title.range(of: " - ", options: .backwards) {
            let suffix = title[dash.upperBound...].lowercased()
            let editions = ["remaster", "version", "edit", "mix", "mono", "stereo", "live", "acoustic", "demo", "single"]
            if editions.contains(where: suffix.contains) { title = String(title[..<dash.lowerBound]) }
        }
        let cleaned = title.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? value : cleaned
    }
}

public struct YouTubeVideo: Codable, Sendable, Equatable, Identifiable {
    public enum Origin: String, Codable, Sendable { case musicBrainz, youTubeSearch, chosen }
    public var id: String
    public var title: String
    public var channel: String
    public var origin: Origin
    /// False when YouTube's oEmbed refuses the video: its owner disabled playback in other sites and apps.
    public var isEmbeddable: Bool

    public init(id: String, title: String, channel: String, origin: Origin, isEmbeddable: Bool = true) {
        self.id = id; self.title = title; self.channel = channel; self.origin = origin; self.isEmbeddable = isEmbeddable
    }

    public var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }

    /// Accepts watch, short, embed, Shorts, and YouTube Music addresses.
    public static func videoID(from url: URL) -> String? {
        guard let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let candidate: String?
        if host == "youtu.be" {
            candidate = url.pathComponents.dropFirst().first
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com") {
            let parts = Array(url.pathComponents.dropFirst())
            if parts.first == "watch" { candidate = components?.queryItems?.first { $0.name == "v" }?.value }
            else if ["embed", "shorts", "live", "v"].contains(parts.first ?? ""), parts.count > 1 { candidate = parts[1] }
            else { candidate = nil }
        } else { candidate = nil }
        guard let candidate, candidate.count == 11,
              candidate.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }) else { return nil }
        return candidate
    }
}

/// What Macarok knows about a song's links, including searches that found nothing.
public struct SongLinkEntry: Sendable, Equatable {
    public var video: YouTubeVideo?
    public var videoCheckedAt: Date?
    public var videoSearchedWithKey = false
    public var wikipedia: URL?
    public var wikipediaCheckedAt: Date?
    public init() {}
}

public enum SongLinkStorage {
    public static func registerMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("song-links-v1") { db in
            try db.execute(sql: """
                CREATE TABLE songLinks (
                    songKey TEXT PRIMARY KEY NOT NULL,
                    video BLOB,
                    videoCheckedAt DOUBLE,
                    videoSearchedWithKey BOOLEAN NOT NULL DEFAULT 0,
                    wikipedia TEXT,
                    wikipediaCheckedAt DOUBLE
                );
                """)
        }
    }
}

extension LibraryStore {
    public func songLinks(_ key: SongKey) throws -> SongLinkEntry {
        try database.read { db in
            var entry = SongLinkEntry()
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM songLinks WHERE songKey = ?", arguments: [key.id]) else { return entry }
            if let data: Data = row["video"] { entry.video = try? JSONDecoder().decode(YouTubeVideo.self, from: data) }
            entry.videoCheckedAt = (row["videoCheckedAt"] as Double?).map(Date.init(timeIntervalSince1970:))
            entry.videoSearchedWithKey = row["videoSearchedWithKey"]
            entry.wikipedia = (row["wikipedia"] as String?).flatMap(URL.init(string:))
            entry.wikipediaCheckedAt = (row["wikipediaCheckedAt"] as Double?).map(Date.init(timeIntervalSince1970:))
            return entry
        }
    }

    /// An automatic result never replaces a video the listener chose.
    public func saveSongVideo(_ video: YouTubeVideo?, for key: SongKey, searchedWithKey: Bool = false, now: Date = Date()) throws {
        let payload = try video.map { try JSONEncoder().encode($0) }
        try database.write { db in
            if video?.origin != .chosen, let data: Data = try Data.fetchOne(db, sql: "SELECT video FROM songLinks WHERE songKey = ?", arguments: [key.id]),
               (try? JSONDecoder().decode(YouTubeVideo.self, from: data))?.origin == .chosen { return }
            try db.execute(sql: """
                INSERT INTO songLinks(songKey, video, videoCheckedAt, videoSearchedWithKey) VALUES (?, ?, ?, ?)
                ON CONFLICT(songKey) DO UPDATE SET video = excluded.video, videoCheckedAt = excluded.videoCheckedAt,
                    videoSearchedWithKey = excluded.videoSearchedWithKey
                """, arguments: [key.id, payload, now.timeIntervalSince1970, searchedWithKey])
        }
    }

    public func forgetSongVideo(for key: SongKey) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE songLinks SET video = NULL, videoCheckedAt = NULL, videoSearchedWithKey = 0 WHERE songKey = ?", arguments: [key.id])
        }
    }

    public func saveSongWikipedia(_ url: URL?, for key: SongKey, now: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO songLinks(songKey, wikipedia, wikipediaCheckedAt) VALUES (?, ?, ?)
                ON CONFLICT(songKey) DO UPDATE SET wikipedia = excluded.wikipedia, wikipediaCheckedAt = excluded.wikipediaCheckedAt
                """, arguments: [key.id, url?.absoluteString, now.timeIntervalSince1970])
        }
    }
}

public enum SongLinkError: LocalizedError, Equatable {
    case invalidAPIKey, quotaExceeded, http(Int), invalidResponse
    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey: "YouTube rejected the API key. Check it in Settings › Services."
        case .quotaExceeded: "Today's YouTube search quota is used up. It resets at midnight Pacific Time."
        case .http(let status): "The service answered with HTTP status \(status)."
        case .invalidResponse: "The service returned an unexpected response."
        }
    }
}

/// Network lookups for a song's YouTube video and Wikipedia article. Results are not cached here; see SongLinkResolver.
public actor SongLinkClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public static let userAgent = "Macarok/0.8 (macOS; https://github.com/armateurlabs/macarok)"

    private let transport: Transport
    private let sleep: @Sendable (Duration) async throws -> Void
    private var lastMusicBrainzRequest: ContinuousClock.Instant?

    public init(transport: Transport? = nil, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        let session = URLSession(configuration: .ephemeral)
        self.transport = transport ?? { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw SongLinkError.invalidResponse }
            return (data, response)
        }
        self.sleep = sleep
    }

    // MARK: MusicBrainz

    /// The first YouTube link attached to a matching MusicBrainz recording, if any.
    public func musicBrainzVideoID(for key: SongKey) async throws -> String? {
        var search = URLComponents(string: "https://musicbrainz.org/ws/2/recording")!
        search.queryItems = [.init(name: "query", value: "recording:\(Self.phrase(key.title)) AND artist:\(Self.phrase(key.artist))"),
                             .init(name: "fmt", value: "json"), .init(name: "limit", value: "25")]
        let results = try await musicBrainz(search.url!)
        let ids = Self.recordingIDs(results, title: key.title)
        for id in ids.prefix(3) {
            let detail = try await musicBrainz(URL(string: "https://musicbrainz.org/ws/2/recording/\(id)?inc=url-rels&fmt=json")!)
            if let video = Self.youTubeID(inRecording: detail) { return video }
        }
        return nil
    }

    /// MusicBrainz allows one request per second per client.
    private func musicBrainz(_ url: URL) async throws -> Data {
        if let last = lastMusicBrainzRequest {
            let wait = Duration.milliseconds(1_100) - (ContinuousClock.now - last)
            if wait > .zero { try await sleep(wait) }
        }
        lastMusicBrainzRequest = .now
        do { return try await get(url) } catch SongLinkError.http(503) {
            // Over the rate limit: MusicBrainz asks clients to slow down, then try again.
            try await sleep(.seconds(2)); lastMusicBrainzRequest = .now
            return try await get(url)
        }
    }

    static func phrase(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: " ").replacingOccurrences(of: "\"", with: " ") + "\""
    }

    /// Music videos first, then the recording found on the most releases; DJ mixes and live takes rarely carry the song's video.
    static func recordingIDs(_ data: Data, title: String) -> [String] {
        struct Response: Decodable {
            struct Recording: Decodable {
                struct Release: Decodable {}
                let id: String; let score: Int?; let title: String; let video: Bool?; let disambiguation: String?; let releases: [Release]?
            }
            let recordings: [Recording]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        let wanted = SongKey.folded(title)
        let candidates = (response.recordings ?? []).filter { recording in
            let note = SongKey.folded(recording.disambiguation ?? "")
            return (recording.score ?? 0) >= 80 && SongKey.folded(SongKey.cleanTitle(recording.title)) == wanted
                && !["mix", "live", "remix", "karaoke", "instrumental"].contains(where: note.contains)
        }
        return candidates.enumerated().sorted { first, second in
            let a = first.element, b = second.element
            if (a.video ?? false) != (b.video ?? false) { return a.video ?? false }
            let releasesA = a.releases?.count ?? 0, releasesB = b.releases?.count ?? 0
            return releasesA != releasesB ? releasesA > releasesB : first.offset < second.offset
        }.map(\.element.id)
    }

    static func youTubeID(inRecording data: Data) -> String? {
        struct Response: Decodable { struct Relation: Decodable { struct Link: Decodable { let resource: String }; let url: Link? }; let relations: [Relation]? }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let urls = (response.relations ?? []).compactMap { $0.url.flatMap { URL(string: $0.resource) } }
        // A regular YouTube video before a YouTube Music one: both play, but the former is the one people share.
        let sorted = urls.sorted { ($0.host == "music.youtube.com" ? 1 : 0) < ($1.host == "music.youtube.com" ? 1 : 0) }
        return sorted.lazy.compactMap(YouTubeVideo.videoID).first
    }

    // MARK: YouTube

    /// Title, channel, and whether the video may be embedded. Nil when the video no longer exists.
    public func videoDetails(id: String, origin: YouTubeVideo.Origin) async throws -> YouTubeVideo? {
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [.init(name: "url", value: "https://www.youtube.com/watch?v=\(id)"), .init(name: "format", value: "json")]
        let (data, response) = try await transport(request(components.url!))
        switch response.statusCode {
        case 200:
            struct Details: Decodable { let title: String; let author_name: String? }
            guard let details = try? JSONDecoder().decode(Details.self, from: data) else { throw SongLinkError.invalidResponse }
            return YouTubeVideo(id: id, title: details.title, channel: details.author_name ?? "", origin: origin)
        case 401, 403: return YouTubeVideo(id: id, title: "", channel: "", origin: origin, isEmbeddable: false)
        case 400, 404: return nil
        default: throw SongLinkError.http(response.statusCode)
        }
    }

    /// Up to five music videos from the YouTube Data API, best match first.
    public func searchYouTube(for key: SongKey, apiKey: String) async throws -> [YouTubeVideo] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        components.queryItems = [.init(name: "part", value: "snippet"), .init(name: "type", value: "video"),
                                 .init(name: "videoCategoryId", value: "10"), .init(name: "maxResults", value: "5"),
                                 .init(name: "q", value: "\(key.artist) \(key.title)"), .init(name: "key", value: apiKey)]
        let (data, response) = try await transport(request(components.url!))
        guard response.statusCode == 200 else { throw Self.youTubeError(status: response.statusCode, data: data) }
        return try Self.searchResults(data)
    }

    static func searchResults(_ data: Data) throws -> [YouTubeVideo] {
        struct Response: Decodable {
            struct Item: Decodable {
                struct ID: Decodable { let videoId: String? }
                struct Snippet: Decodable { let title: String; let channelTitle: String? }
                let id: ID; let snippet: Snippet
            }
            let items: [Item]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw SongLinkError.invalidResponse }
        return (response.items ?? []).compactMap { item in
            item.id.videoId.map { YouTubeVideo(id: $0, title: htmlDecoded(item.snippet.title), channel: htmlDecoded(item.snippet.channelTitle ?? ""), origin: .youTubeSearch) }
        }
    }

    static func youTubeError(status: Int, data: Data) -> SongLinkError {
        let text = String(decoding: data, as: UTF8.self)
        if status == 403, text.contains("quotaExceeded") || text.contains("dailyLimitExceeded") { return .quotaExceeded }
        if status == 400 || status == 403, text.contains("keyInvalid") || text.contains("API_KEY_INVALID") || text.contains("API key not valid") { return .invalidAPIKey }
        return .http(status)
    }

    /// The Data API escapes titles as HTML.
    static func htmlDecoded(_ value: String) -> String {
        [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&#039;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">")]
            .reduce(value) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    // MARK: Wikipedia

    /// The song's English Wikipedia article, otherwise the artist's.
    public func wikipediaURL(for key: SongKey) async throws -> URL? {
        let songPages = try await wikipediaSearch("\(key.title) \(key.artist) song")
        if let song = Self.songArticle(songPages, key: key) { return song }
        if let artist = Self.artistArticle(songPages, key: key) { return artist }
        return Self.artistArticle(try await wikipediaSearch(key.artist), key: key)
    }

    struct WikipediaPage: Decodable {
        let title: String
        let index: Int?
        let fullurl: String?
        let pageprops: [String: String]?
        var description: String { SongKey.folded(pageprops?["wikibase-shortdesc"] ?? "") }
        var isDisambiguation: Bool { pageprops?["disambiguation"] != nil }
        /// "Home (Depeche Mode song)" is about "Home".
        var baseTitle: String { SongKey.folded(title.replacingOccurrences(of: #"\s*\([^\)]*\)$"#, with: "", options: .regularExpression)) }
    }

    private func wikipediaSearch(_ query: String) async throws -> [WikipediaPage] {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [.init(name: "action", value: "query"), .init(name: "generator", value: "search"),
                                 .init(name: "gsrsearch", value: query), .init(name: "gsrlimit", value: "5"),
                                 .init(name: "prop", value: "pageprops|info"), .init(name: "ppprop", value: "disambiguation|wikibase-shortdesc"),
                                 .init(name: "inprop", value: "url"), .init(name: "format", value: "json"), .init(name: "formatversion", value: "2")]
        return Self.wikipediaPages(try await get(components.url!))
    }

    static func wikipediaPages(_ data: Data) -> [WikipediaPage] {
        struct Response: Decodable { struct Query: Decodable { let pages: [WikipediaPage]? }; let query: Query? }
        let pages = (try? JSONDecoder().decode(Response.self, from: data))?.query?.pages ?? []
        return pages.sorted { ($0.index ?? .max) < ($1.index ?? .max) }
    }

    static func songArticle(_ pages: [WikipediaPage], key: SongKey) -> URL? {
        let title = SongKey.folded(key.title), artist = SongKey.folded(key.artist)
        return pages.first { page in
            !page.isDisambiguation && page.baseTitle == title
                && ["song", "single", "composition", "instrumental"].contains(where: page.description.contains)
                && page.description.contains(artist)
        }?.fullurl.flatMap(URL.init(string:))
    }

    static func artistArticle(_ pages: [WikipediaPage], key: SongKey) -> URL? {
        let artist = SongKey.folded(key.artist)
        let roles = ["band", "singer", "musician", "rapper", "group", "duo", "trio", "quartet", "composer", "songwriter",
                     "dj", "orchestra", "producer", "ensemble", "artist", "vocalist", "guitarist", "pianist", "collective"]
        return pages.first { page in
            !page.isDisambiguation && page.baseTitle == artist && roles.contains(where: page.description.contains)
        }?.fullurl.flatMap(URL.init(string:))
    }

    // MARK: HTTP

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await transport(request(url))
        guard response.statusCode == 200 else { throw SongLinkError.http(response.statusCode) }
        return data
    }
}

/// Combines the cache and the lookup chain: a MusicBrainz link, then the YouTube Data API when a key is set.
public actor SongLinkResolver {
    public struct VideoResult: Sendable, Equatable {
        public var video: YouTubeVideo?
        public var alternatives: [YouTubeVideo]
        public init(video: YouTubeVideo?, alternatives: [YouTubeVideo] = []) { self.video = video; self.alternatives = alternatives }
    }

    static let notFoundRetry: TimeInterval = 7 * 86_400
    static let wikipediaRefresh: TimeInterval = 30 * 86_400

    private let store: LibraryStore
    private let client: SongLinkClient
    private let now: @Sendable () -> Date

    public init(store: LibraryStore, client: SongLinkClient = SongLinkClient(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.client = client; self.now = now
    }

    public func cachedVideo(for key: SongKey) -> YouTubeVideo? { (try? store.songLinks(key))?.video }

    public func video(for key: SongKey, apiKey: String?) async throws -> VideoResult {
        let entry = try store.songLinks(key)
        if let video = entry.video { return VideoResult(video: video) }
        let hasKey = !(apiKey ?? "").isEmpty
        if let checked = entry.videoCheckedAt, now().timeIntervalSince(checked) < Self.notFoundRetry, entry.videoSearchedWithKey || !hasKey {
            return VideoResult(video: nil)
        }
        // MusicBrainz is often busy; its failure must not hide the other ways to find a video.
        var musicBrainzAnswered = true
        do {
            if let id = try await client.musicBrainzVideoID(for: key), let video = try await client.videoDetails(id: id, origin: .musicBrainz) {
                try store.saveSongVideo(video, for: key, searchedWithKey: hasKey, now: now())
                return VideoResult(video: video)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { musicBrainzAnswered = false }
        guard let apiKey, hasKey else {
            if musicBrainzAnswered { try store.saveSongVideo(nil, for: key, now: now()) }
            return VideoResult(video: nil)
        }
        let results = try await client.searchYouTube(for: key, apiKey: apiKey)
        try store.saveSongVideo(results.first, for: key, searchedWithKey: true, now: now())
        return VideoResult(video: results.first, alternatives: Array(results.dropFirst()))
    }

    /// Other candidates for "Other Videos"; requires an API key.
    public func alternatives(for key: SongKey, apiKey: String, excluding id: String?) async throws -> [YouTubeVideo] {
        try await client.searchYouTube(for: key, apiKey: apiKey).filter { $0.id != id }
    }

    /// The listener's pick wins over every automatic match for this song.
    public func choose(videoID: String, for key: SongKey) async throws -> YouTubeVideo {
        let details = try? await client.videoDetails(id: videoID, origin: .chosen)
        let video = details ?? YouTubeVideo(id: videoID, title: "", channel: "", origin: .chosen)
        try store.saveSongVideo(video, for: key, now: now())
        return video
    }

    public func choose(_ video: YouTubeVideo, for key: SongKey) throws {
        var chosen = video; chosen.origin = .chosen
        try store.saveSongVideo(chosen, for: key, now: now())
    }

    public func forgetVideo(for key: SongKey) throws { try store.forgetSongVideo(for: key) }

    public func markNotEmbeddable(_ video: YouTubeVideo, for key: SongKey) throws {
        guard video.isEmbeddable else { return }
        var updated = video; updated.isEmbeddable = false
        if video.origin == .chosen { try store.saveSongVideo(updated, for: key, now: now()) }
        else { try store.saveSongVideo(updated, for: key, searchedWithKey: (try? store.songLinks(key))?.videoSearchedWithKey ?? false, now: now()) }
    }

    public func wikipedia(for key: SongKey) async throws -> URL? {
        let entry = try store.songLinks(key)
        if let checked = entry.wikipediaCheckedAt {
            let age = now().timeIntervalSince(checked)
            if entry.wikipedia != nil ? age < Self.wikipediaRefresh : age < Self.notFoundRetry { return entry.wikipedia }
        }
        let url = try await client.wikipediaURL(for: key)
        try store.saveSongWikipedia(url, for: key, now: now())
        return url
    }
}

/// The optional personal YouTube Data API key, kept in Keychain and read only when a lookup needs it.
public struct YouTubeKeychainStore: Sendable {
    private let service: String
    public init(service: String = "labs.armateur.Macarok.youtube") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "data-api-key"]
    }
    public func load() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SourceNetworkError.keychain(status) }
        return (result as? Data).map { String(decoding: $0, as: UTF8.self) }
    }
    public func save(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw SourceNetworkError.keychain(added) }
        } else if status != errSecSuccess { throw SourceNetworkError.keychain(status) }
    }
    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SourceNetworkError.keychain(status) }
    }
}

/// Plain text for the macOS share menu: what is playing, then the links Macarok knows. No app signature.
public enum ShareText {
    public static func song(title: String, artist: String, links: [URL]) -> String {
        lines([[title, artist].filter { !$0.isEmpty }.joined(separator: " — ")] + links.map(\.absoluteString))
    }

    public static func radio(station: String, nowPlaying: String?, website: URL?) -> String {
        lines([[station, nowPlaying ?? ""].filter { !$0.isEmpty }.joined(separator: " — "), website?.absoluteString ?? ""])
    }

    public static func podcast(show: String, episode: String, link: URL?) -> String {
        lines([[show, episode].filter { !$0.isEmpty }.joined(separator: " — "), link?.absoluteString ?? ""])
    }

    public static func video(_ video: YouTubeVideo) -> String { lines([video.title, video.watchURL.absoluteString]) }

    private static func lines(_ values: [String]) -> String {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n")
    }
}
