import Foundation

/// Internet Archive audio collections offered as browsable sources.
public enum ArchiveCollection: String, Codable, Sendable, CaseIterable {
    case liveMusic = "etree"
    case librivox = "librivoxaudio"

    public var title: String { self == .liveMusic ? "Live Music Archive" : "LibriVox" }
    public var location: String { "https://archive.org/details/\(rawValue)" }
    public var genre: String { self == .liveMusic ? "Live" : "Audiobook" }

    public init?(location: String) {
        guard let url = URL(string: location), let host = url.host?.lowercased(),
              host == "archive.org" || host.hasSuffix(".archive.org") else { return nil }
        self.init(rawValue: url.lastPathComponent)
    }
}

extension SourceRecord {
    public var archiveCollection: ArchiveCollection? {
        kind == .internetArchive ? ArchiveCollection(location: location) : nil
    }
}

public enum ArchiveAudioQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case high, standard
    public var id: String { rawValue }
    public var title: String { self == .high ? "High (lossless when available)" : "Standard (MP3)" }

    /// Earlier formats win; any listed format is playable.
    public var preferredFormats: [String] {
        switch self {
        case .high:
            ["24bit Flac", "Flac", "Apple Lossless Audio", "WAVE", "AIFF", "320Kbps MP3", "256Kbps MP3", "192Kbps MP3",
             "128Kbps MP3", "VBR MP3", "Ogg Vorbis", "MP3", "96Kbps MP3", "64Kbps MP3", "32Kbps MP3"]
        case .standard:
            ["64Kbps MP3", "VBR MP3", "128Kbps MP3", "96Kbps MP3", "Ogg Vorbis", "MP3", "192Kbps MP3", "256Kbps MP3",
             "320Kbps MP3", "32Kbps MP3", "Flac", "24bit Flac", "Apple Lossless Audio", "WAVE", "AIFF"]
        }
    }
}

public enum ArchiveSort: String, Codable, Sendable, CaseIterable, Identifiable {
    case popular, newest, alphabetical
    public var id: String { rawValue }
    public var title: String {
        switch self { case .popular: "Popular"; case .newest: "Recently Added"; case .alphabetical: "A–Z" }
    }
}

public enum ArchiveBrowseRequest: Hashable, Sendable {
    /// Live Music Archive artist collections.
    case artists(search: String, sort: ArchiveSort)
    /// Recordings in one artist collection, optionally limited to a year.
    case shows(artist: String, year: Int?)
    /// LibriVox books, optionally limited to a MARC language code.
    case books(search: String, language: String?, sort: ArchiveSort)
}

public struct ArchiveSearchResult: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var creator: String
    public var date: String?
    public var year: Int?
    public var venue: String?
    public var coverage: String?
    public var recordingSource: String?
    public var rating: Double?
    public var downloads: Int?
    public var itemCount: Int?
    public var language: String?

    public init(id: String, title: String, creator: String = "", date: String? = nil, year: Int? = nil,
                venue: String? = nil, coverage: String? = nil, recordingSource: String? = nil,
                rating: Double? = nil, downloads: Int? = nil, itemCount: Int? = nil, language: String? = nil) {
        self.id = id; self.title = title; self.creator = creator; self.date = date; self.year = year
        self.venue = venue; self.coverage = coverage; self.recordingSource = recordingSource
        self.rating = rating; self.downloads = downloads; self.itemCount = itemCount; self.language = language
    }

    public var artworkURL: URL { InternetArchiveClient.artworkURL(identifier: id) }
}

public struct ArchiveSearchPage: Sendable, Equatable {
    public var results: [ArchiveSearchResult]
    public var total: Int
    public var page: Int
    public var pageSize: Int
    public var hasMore: Bool { page * pageSize < total }
}

public struct ArchiveYearCount: Sendable, Hashable, Identifiable {
    public var year: Int
    public var count: Int
    public var id: Int { year }
}

public struct ArchiveFile: Codable, Sendable, Equatable {
    public var name: String
    public var format: String
    public var isOriginal: Bool
    public var original: String?
    public var title: String?
    public var track: String?
    public var length: Double?
    public var isPrivate: Bool

    public init(name: String, format: String, isOriginal: Bool = true, original: String? = nil, title: String? = nil,
                track: String? = nil, length: Double? = nil, isPrivate: Bool = false) {
        self.name = name; self.format = format; self.isOriginal = isOriginal; self.original = original
        self.title = title; self.track = track; self.length = length; self.isPrivate = isPrivate
    }
}

public struct ArchiveTrackFile: Sendable, Equatable {
    /// The original file name, stable when the preferred format changes.
    public var key: String
    public var file: ArchiveFile
    public var title: String
    public var number: Int?
    public var duration: Double
}

public struct ArchiveItem: Codable, Sendable, Equatable {
    public var identifier: String
    public var title: String
    public var creator: String
    public var date: String?
    public var venue: String?
    public var coverage: String?
    public var description: String
    public var recordingSource: String?
    public var lineage: String?
    public var taper: String?
    public var language: String?
    public var collections: [String]
    public var files: [ArchiveFile]

    public init(identifier: String, title: String, creator: String = "", date: String? = nil, venue: String? = nil,
                coverage: String? = nil, description: String = "", recordingSource: String? = nil, lineage: String? = nil,
                taper: String? = nil, language: String? = nil, collections: [String] = [], files: [ArchiveFile] = []) {
        self.identifier = identifier; self.title = title; self.creator = creator; self.date = date; self.venue = venue
        self.coverage = coverage; self.description = description; self.recordingSource = recordingSource
        self.lineage = lineage; self.taper = taper; self.language = language; self.collections = collections; self.files = files
    }

    public var year: Int? { date.flatMap { Int($0.prefix(4)) } }
    public var pageURL: URL { URL(string: "https://archive.org/details/")!.appendingPathComponent(identifier) }

    /// Live recordings are named by date and place; several recordings of one show stay distinguishable by source.
    public func albumTitle(for collection: ArchiveCollection) -> String {
        guard collection == .liveMusic, let date, date.count >= 10 else { return title }
        let place = [venue, coverage].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return place.isEmpty ? title : "\(date.prefix(10)) \(place.joined(separator: ", "))"
    }

    public func audioTracks(quality: ArchiveAudioQuality) -> [ArchiveTrackFile] {
        let preference = quality.preferredFormats
        let playable = Set(preference)
        let byName = Dictionary(files.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let audioOriginals = playable.union(["Shorten", "Flac"])
        var groups: [String: [ArchiveFile]] = [:]
        var order: [String] = []
        for file in files where playable.contains(file.format) {
            let key = file.isOriginal ? file.name : (file.original ?? file.name)
            // Audio derived from video or other non-audio originals is not a track.
            if let origin = byName[key], !audioOriginals.contains(origin.format) { continue }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(file)
        }
        let tracks: [ArchiveTrackFile] = order.compactMap { key in
            let members = groups[key] ?? []
            let candidates = members.filter { !$0.isPrivate }
                .sorted { (preference.firstIndex(of: $0.format) ?? .max) < (preference.firstIndex(of: $1.format) ?? .max) }
            guard let chosen = candidates.first else { return nil }
            let described = [byName[key]].compactMap { $0 } + members
            let title = described.lazy.compactMap { $0.title?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
                ?? ((key as NSString).lastPathComponent as NSString).deletingPathExtension
            let number = described.lazy.compactMap { Self.trackNumber($0.track) }.first
            let duration = described.lazy.compactMap(\.length).first { $0 > 0 } ?? 0
            return ArchiveTrackFile(key: key, file: chosen, title: title, number: number, duration: duration)
        }
        return tracks.sorted {
            switch ($0.number, $1.number) {
            case let (left?, right?) where left != right: return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            default: return $0.key.localizedStandardCompare($1.key) == .orderedAscending
            }
        }
    }

    public func trackRecords(sourceID: String, collection: ArchiveCollection, quality: ArchiveAudioQuality,
                             artworkPath: String? = nil) -> [TrackRecord] {
        let artist = creator.isEmpty ? collection.title : creator
        let album = albumTitle(for: collection)
        let albumID = StableID.make(sourceID, "archive-item", identifier)
        return audioTracks(quality: quality).enumerated().map { index, track in
            let url = InternetArchiveClient.downloadURL(identifier: identifier, file: track.file.name)
            let suffix = (track.file.name as NSString).pathExtension.uppercased()
            return TrackRecord(id: StableID.make(sourceID, "archive", identifier, track.key), sourceID: sourceID, albumID: albumID,
                               title: track.title, artist: artist, albumArtist: artist, album: album,
                               year: collection == .liveMusic ? year : nil, genre: collection.genre,
                               trackNumber: track.number ?? index + 1, duration: track.duration,
                               fileURL: url.absoluteString, remoteID: identifier,
                               remotePath: "\(artist)/\(identifier)/\(track.key)", coverArtID: identifier,
                               format: suffix.isEmpty ? "MP3" : suffix, artworkPath: artworkPath)
        }
    }

    static func trackNumber(_ value: String?) -> Int? {
        guard let value else { return nil }
        let digits = value.split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return Int(digits)
    }
}

public enum ArchiveError: LocalizedError, Sendable, Equatable {
    case invalidResponse
    case itemUnavailable(String)
    case noPlayableAudio(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "The Internet Archive returned an unexpected response. Try again later."
        case .itemUnavailable(let id): "“\(id)” is not available on the Internet Archive."
        case .noPlayableAudio(let id): "“\(id)” has no audio files that can be streamed."
        }
    }
}

/// Stores raw Internet Archive responses so browsing can reuse and fall back to earlier results.
public protocol ArchiveResponseCache: Sendable {
    func cachedArchiveResponse(key: String, maxAge: TimeInterval?, now: Date) throws -> Data?
    func saveArchiveResponse(_ data: Data, key: String, now: Date) throws
}

public struct ArchiveResponse<Value: Sendable>: Sendable {
    public var value: Value
    /// The network was unavailable and an expired cached response was used.
    public var isStale: Bool
}

public struct InternetArchiveClient: Sendable {
    public static let userAgent = "Macarok/0.3 (macOS; https://github.com/armateurlabs/macarok)"
    public static let listingMaxAge: TimeInterval = 24 * 60 * 60
    public static let itemMaxAge: TimeInterval = 7 * 24 * 60 * 60
    public static let languages: [(code: String, name: String)] = [
        ("eng", "English"), ("fre", "French"), ("ger", "German"), ("spa", "Spanish"), ("ita", "Italian"),
        ("dut", "Dutch"), ("por", "Portuguese"), ("rus", "Russian"), ("pol", "Polish"), ("chi", "Chinese"),
        ("jpn", "Japanese"), ("lat", "Latin"), ("grc", "Ancient Greek"), ("fin", "Finnish"), ("swe", "Swedish"),
        ("dan", "Danish"), ("heb", "Hebrew"), ("hun", "Hungarian"), ("tag", "Tagalog"), ("esp", "Esperanto"),
    ]

    public let transport: SourceTransport
    public let cache: ArchiveResponseCache?
    private let now: @Sendable () -> Date

    public init(transport: SourceTransport, cache: ArchiveResponseCache? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport; self.cache = cache; self.now = now
    }

    public func search(_ request: ArchiveBrowseRequest, collection: ArchiveCollection, page: Int,
                       pageSize: Int = 50) async throws -> ArchiveResponse<ArchiveSearchPage> {
        let url = Self.searchURL(request, collection: collection, page: page, pageSize: pageSize)
        let response = try await load(url, maxAge: Self.listingMaxAge)
        return ArchiveResponse(value: try Self.parseSearch(data: response.value, page: page, pageSize: pageSize), isStale: response.isStale)
    }

    public func years(artist: String) async throws -> ArchiveResponse<[ArchiveYearCount]> {
        var counts: [Int: Int] = [:]
        var cursor: String?
        var stale = false
        repeat {
            try Task.checkCancellation()
            let response = try await load(Self.yearsURL(artist: artist, cursor: cursor), maxAge: Self.listingMaxAge)
            stale = stale || response.isStale
            let page = try Self.parseYears(data: response.value)
            for (year, count) in page.counts { counts[year, default: 0] += count }
            cursor = page.cursor
        } while cursor != nil
        let years = counts.map { ArchiveYearCount(year: $0.key, count: $0.value) }.sorted { $0.year > $1.year }
        return ArchiveResponse(value: years, isStale: stale)
    }

    public func item(identifier: String, maxAge: TimeInterval? = InternetArchiveClient.itemMaxAge) async throws -> ArchiveResponse<ArchiveItem> {
        let url = URL(string: "https://archive.org/metadata/")!.appendingPathComponent(identifier)
        let response = try await load(url, maxAge: maxAge)
        return ArchiveResponse(value: try Self.parseItem(data: response.value, identifier: identifier), isStale: response.isStale)
    }

    func load(_ url: URL, maxAge: TimeInterval?) async throws -> ArchiveResponse<Data> {
        let key = url.absoluteString
        if let maxAge, let cached = try? cache?.cachedArchiveResponse(key: key, maxAge: maxAge, now: now()) {
            return ArchiveResponse(value: cached, isStale: false)
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await transport.data(for: request)
            try? cache?.saveArchiveResponse(data, key: key, now: now())
            return ArchiveResponse(value: data, isStale: false)
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            if let stale = try? cache?.cachedArchiveResponse(key: key, maxAge: nil, now: now()) {
                return ArchiveResponse(value: stale, isStale: true)
            }
            throw error
        }
    }

    // MARK: URLs

    public static func artworkURL(identifier: String) -> URL {
        URL(string: "https://archive.org/services/img/")!.appendingPathComponent(identifier)
    }

    public static func downloadURL(identifier: String, file: String) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#&+=")
        let path = ([identifier] + file.split(separator: "/").map(String.init))
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }.joined(separator: "/")
        return URL(string: "https://archive.org/download/\(path)")!
    }

    public static func searchURL(_ request: ArchiveBrowseRequest, collection: ArchiveCollection, page: Int, pageSize: Int) -> URL {
        let query: String, fields: [String], sort: String
        switch request {
        case .artists(let search, let order):
            query = (["collection:\(collection.rawValue)", "mediatype:collection"] + terms(search, fields: ["title"])).joined(separator: " AND ")
            fields = ["identifier", "title", "item_count", "downloads"]
            sort = order == .alphabetical ? "titleSorter asc" : order == .newest ? "publicdate desc" : "downloads desc"
        case .shows(let artist, let year):
            query = (["collection:\(sanitizedIdentifier(artist))", "mediatype:etree"] + (year.map { ["year:\($0)"] } ?? [])).joined(separator: " AND ")
            fields = ["identifier", "title", "creator", "date", "year", "venue", "coverage", "source", "avg_rating", "downloads"]
            sort = year == nil ? "date desc" : "date asc"
        case .books(let search, let language, let order):
            query = (["collection:\(collection.rawValue)"] + terms(search, fields: ["title", "creator"])
                     + (language.map { ["language:\(sanitizedIdentifier($0))"] } ?? [])).joined(separator: " AND ")
            fields = ["identifier", "title", "creator", "date", "language", "downloads", "avg_rating"]
            sort = order == .alphabetical ? "titleSorter asc" : order == .newest ? "publicdate desc" : "downloads desc"
        }
        var components = URLComponents(string: "https://archive.org/advancedsearch.php")!
        components.queryItems = [URLQueryItem(name: "q", value: query)] + fields.map { URLQueryItem(name: "fl[]", value: $0) }
            + [URLQueryItem(name: "sort[]", value: sort), URLQueryItem(name: "rows", value: String(pageSize)),
               URLQueryItem(name: "page", value: String(max(1, page))), URLQueryItem(name: "output", value: "json")]
        return components.url!
    }

    static func yearsURL(artist: String, cursor: String?) -> URL {
        var components = URLComponents(string: "https://archive.org/services/search/v1/scrape")!
        components.queryItems = [URLQueryItem(name: "q", value: "collection:\(sanitizedIdentifier(artist)) AND mediatype:etree"),
                                 URLQueryItem(name: "fields", value: "year"), URLQueryItem(name: "count", value: "10000")]
            + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        return components.url!
    }

    /// User text never reaches the Lucene query syntax; each word must match.
    static func terms(_ search: String, fields: [String]) -> [String] {
        // Lowercase words cannot become AND/OR/NOT operators.
        let words = search.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.prefix(8)
        guard !words.isEmpty else { return [] }
        let value = words.enumerated().map { $0.offset == words.count - 1 ? "\($0.element)*" : $0.element }.joined(separator: " AND ")
        return ["(" + fields.map { "\($0):(\(value))" }.joined(separator: " OR ") + ")"]
    }

    static func sanitizedIdentifier(_ value: String) -> String {
        String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) })
    }

    // MARK: Parsing

    public static func parseSearch(data: Data, page: Int, pageSize: Int) throws -> ArchiveSearchPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any], let docs = response["docs"] as? [[String: Any]] else {
            throw ArchiveError.invalidResponse
        }
        let results = docs.compactMap { doc -> ArchiveSearchResult? in
            guard let id = string(doc["identifier"]) else { return nil }
            let date = string(doc["date"]).map { String($0.prefix(10)) }
            return ArchiveSearchResult(id: id, title: string(doc["title"]) ?? id, creator: string(doc["creator"]) ?? "",
                                       date: date, year: int(doc["year"]) ?? date.flatMap { Int($0.prefix(4)) },
                                       venue: string(doc["venue"]), coverage: string(doc["coverage"]),
                                       recordingSource: string(doc["source"]), rating: double(doc["avg_rating"]),
                                       downloads: int(doc["downloads"]), itemCount: int(doc["item_count"]),
                                       language: string(doc["language"]))
        }
        return ArchiveSearchPage(results: results, total: int(response["numFound"]) ?? results.count, page: page, pageSize: pageSize)
    }

    static func parseYears(data: Data) throws -> (counts: [Int: Int], cursor: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { throw ArchiveError.invalidResponse }
        var counts: [Int: Int] = [:]
        for item in items { if let year = int(item["year"]) { counts[year, default: 0] += 1 } }
        let cursor = string(root["cursor"])
        return (counts, items.isEmpty ? nil : cursor)
    }

    public static func parseItem(data: Data, identifier: String) throws -> ArchiveItem {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ArchiveError.invalidResponse }
        guard root["is_dark"] as? Bool != true, let metadata = root["metadata"] as? [String: Any],
              let files = root["files"] as? [[String: Any]] else { throw ArchiveError.itemUnavailable(identifier) }
        let description = (metadata["description"] as? [Any])?.compactMap { string($0) }.joined(separator: "\n")
            ?? string(metadata["description"]) ?? ""
        let collections = (metadata["collection"] as? [Any])?.compactMap { string($0) } ?? string(metadata["collection"]).map { [$0] } ?? []
        return ArchiveItem(
            identifier: string(metadata["identifier"]) ?? identifier,
            title: string(metadata["title"]) ?? identifier,
            creator: string(metadata["creator"]) ?? "",
            date: string(metadata["date"]).map { String($0.prefix(10)) },
            venue: string(metadata["venue"]), coverage: string(metadata["coverage"]),
            description: plainText(description), recordingSource: string(metadata["source"]),
            lineage: string(metadata["lineage"]), taper: string(metadata["taper"]),
            language: string(metadata["language"]), collections: collections,
            files: files.compactMap { file in
                guard let name = string(file["name"]), let format = string(file["format"]) else { return nil }
                return ArchiveFile(name: name, format: format, isOriginal: string(file["source"]) != "derivative",
                                   original: string(file["original"]), title: string(file["title"]), track: string(file["track"]),
                                   length: string(file["length"]).map(PodcastClient.duration(from:)) ?? double(file["length"]),
                                   isPrivate: string(file["private"]) == "true" || file["private"] as? Bool == true)
            })
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber: return value.stringValue
        case let values as [Any]: return values.lazy.compactMap { string($0) }.first
        default: return nil
        }
    }
    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return string(value).flatMap { Int($0) ?? Double($0).map { Int($0) } }
    }
    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return string(value).flatMap(Double.init)
    }
    private static func plainText(_ value: String) -> String {
        value.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
