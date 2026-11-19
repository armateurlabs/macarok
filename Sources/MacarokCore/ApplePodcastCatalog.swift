import Foundation

/// A show listed by the Apple Podcasts directory. Some publishers do not expose their RSS feed there.
public struct PodcastCatalogShow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let author: String
    public let feedURL: URL?
    public let artworkURL: URL?
    public let genre: String
    public let episodeCount: Int?

    public init(id: String, title: String, author: String, feedURL: URL?, artworkURL: URL? = nil, genre: String = "", episodeCount: Int? = nil) {
        self.id = id; self.title = title; self.author = author; self.feedURL = feedURL
        self.artworkURL = artworkURL; self.genre = genre; self.episodeCount = episodeCount
    }
}

/// Apple Podcasts top charts and search by country and genre, the directory Browse view is built on.
public actor ApplePodcastCatalog {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public struct Genre: Identifiable, Hashable, Sendable {
        public let id: Int
        public let title: String
    }

    /// Apple's top-level podcast genres.
    public static let genres: [Genre] = [
        (1301, "Arts"), (1321, "Business"), (1303, "Comedy"), (1304, "Education"), (1483, "Fiction"),
        (1511, "Government"), (1512, "Health & Fitness"), (1487, "History"), (1305, "Kids & Family"), (1502, "Leisure"),
        (1310, "Music"), (1489, "News"), (1314, "Religion & Spirituality"), (1533, "Science"), (1324, "Society & Culture"),
        (1545, "Sports"), (1309, "TV & Film"), (1318, "Technology"), (1488, "True Crime"),
    ].map { Genre(id: $0.0, title: $0.1) }

    /// Storefronts with large podcast catalogs; Apple ranks shows per country, not per language.
    public static let countries = ["us", "gb", "ca", "au", "ie", "fr", "be", "ch", "de", "at", "es", "it", "nl", "se", "no", "dk",
                                   "fi", "pt", "br", "mx", "ar", "jp", "kr", "in", "nz", "za"]

    private let transport: Transport
    private let now: @Sendable () -> Date
    private var cache: [URL: (Date, [PodcastCatalogShow])] = [:]

    public init(transport: Transport? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        let session = URLSession(configuration: .ephemeral)
        self.transport = transport ?? { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw RadioError.invalidResponse }
            return (data, response)
        }
        self.now = now
    }

    /// The most popular shows, in chart order.
    public func top(country: String, genreID: Int? = nil, limit: Int = 50) async throws -> [PodcastCatalogShow] {
        let country = Self.storefront(country)
        let genre = genreID.map { "/genre=\($0)" } ?? ""
        let chart = URL(string: "https://itunes.apple.com/\(country)/rss/toppodcasts/limit=\(min(max(limit, 1), 100))\(genre)/json")!
        if let cached = fresh(chart, for: 3_600) { return cached }
        let ids = try Self.chartIDs(try await get(chart))
        guard !ids.isEmpty else { return [] }
        var lookup = URLComponents(string: "https://itunes.apple.com/lookup")!
        lookup.queryItems = [.init(name: "id", value: ids.joined(separator: ",")), .init(name: "country", value: country),
                             .init(name: "entity", value: "podcast")]
        let found = Dictionary(try Self.shows(try await get(lookup.url!)).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = ids.compactMap { found[$0] }
        cache[chart] = (now(), ordered)
        return ordered
    }

    public func search(_ term: String, country: String, genreID: Int? = nil) async throws -> [PodcastCatalogShow] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        var endpoint = URLComponents(string: "https://itunes.apple.com/search")!
        endpoint.queryItems = [.init(name: "media", value: "podcast"), .init(name: "entity", value: "podcast"), .init(name: "term", value: term),
                               .init(name: "country", value: Self.storefront(country)), .init(name: "limit", value: "50")]
        if let genreID { endpoint.queryItems!.append(.init(name: "genreId", value: String(genreID))) }
        if let cached = fresh(endpoint.url!, for: 600) { return cached }
        let shows = try Self.shows(try await get(endpoint.url!))
        cache[endpoint.url!] = (now(), shows)
        return shows
    }

    public static func storefront(_ country: String) -> String {
        let code = country.lowercased()
        return code.count == 2 && code.allSatisfy(\.isLetter) ? code : "us"
    }

    private func fresh(_ url: URL, for lifetime: TimeInterval) -> [PodcastCatalogShow]? {
        guard let cached = cache[url], now().timeIntervalSince(cached.0) < lifetime else { return nil }
        return cached.1
    }

    private func get(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url); request.timeoutInterval = 20
        request.setValue("Macarok (https://github.com/armateurlabs/macarok)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        if response.statusCode == 429 || response.statusCode == 503 { throw PodcastDirectoryError.throttled(30) }
        guard response.statusCode == 200 else { throw SourceNetworkError.httpStatus(response.statusCode) }
        guard data.count <= 8 * 1_024 * 1_024 else { throw RadioError.invalidResponse }
        return data
    }

    static func chartIDs(_ data: Data) throws -> [String] {
        struct Chart: Decodable {
            struct Feed: Decodable { let entry: [Entry]? }
            struct Entry: Decodable {
                struct ID: Decodable { struct Attributes: Decodable { let id: String; enum CodingKeys: String, CodingKey { case id = "im:id" } }; let attributes: Attributes }
                let id: ID
            }
            let feed: Feed
        }
        do { return try JSONDecoder().decode(Chart.self, from: data).feed.entry?.map(\.id.attributes.id) ?? [] }
        catch { throw RadioError.invalidResponse }
    }

    static func shows(_ data: Data) throws -> [PodcastCatalogShow] {
        struct Payload: Decodable { let results: [Row] }
        struct Row: Decodable {
            let collectionId: Int?; let collectionName: String?; let artistName: String?; let feedUrl: String?
            let artworkUrl600: String?; let artworkUrl100: String?; let primaryGenreName: String?; let trackCount: Int?
        }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) } catch { throw RadioError.invalidResponse }
        var seen: Set<Int> = []
        return payload.results.compactMap { row in
            guard let id = row.collectionId, seen.insert(id).inserted, let title = row.collectionName else { return nil }
            return PodcastCatalogShow(id: String(id), title: title, author: row.artistName ?? "",
                                      feedURL: row.feedUrl.flatMap { try? RadioError.validatedURL($0) },
                                      artworkURL: (row.artworkUrl600 ?? row.artworkUrl100).flatMap { try? RadioError.validatedURL($0) },
                                      genre: row.primaryGenreName ?? "", episodeCount: row.trackCount)
        }
    }
}
