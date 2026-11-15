import Foundation

public enum PodcastDirectoryProvider: String, CaseIterable, Sendable, Identifiable {
    case podcastIndex, apple
    public var id: String { rawValue }
    public var title: String { self == .podcastIndex ? "Podcast Index" : "Apple Podcasts" }
}

public struct PodcastDirectoryResult: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let author: String
    public let feedURL: URL
    public let artworkURL: URL?
    public let provider: PodcastDirectoryProvider
    public init(id: String, title: String, author: String, feedURL: URL, artworkURL: URL? = nil, provider: PodcastDirectoryProvider) {
        self.id = id; self.title = title; self.author = author; self.feedURL = feedURL
        self.artworkURL = artworkURL; self.provider = provider
    }
}

/// Public podcast search only. Subscription and audio come from the publisher's RSS feed.
public actor PodcastDirectoryClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date
    private var cache: [String: (Date, [PodcastDirectoryResult])] = [:]
    private var nextRequest: [PodcastDirectoryProvider: Date] = [:]

    public init(transport: Transport? = nil, sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds(max(0, min($0, 60)))) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        let session = URLSession(configuration: .ephemeral)
        self.transport = transport ?? { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw RadioError.invalidResponse }
            return (data, response)
        }
        self.sleep = sleep; self.now = now
    }

    public func search(query: String, provider: PodcastDirectoryProvider = .podcastIndex) async throws -> [PodcastDirectoryResult] {
        try Task.checkCancellation()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let key = provider.rawValue + ":" + query.lowercased()
        if let cached = cache[key], now().timeIntervalSince(cached.0) < 600 { return cached.1 }
        // A cancelled waiter consumes no slot. Recheck after yielding so concurrent searches remain spaced.
        while let deadline = nextRequest[provider], deadline > now() {
            let delay = deadline.timeIntervalSince(now())
            // Date conversion and injected clocks can round a final fraction below their resolution.
            if delay < 0.001 { break }
            try await sleep(min(60, delay))
            try Task.checkCancellation()
        }
        nextRequest[provider] = now().addingTimeInterval(provider == .apple ? 3.1 : 0.3)
        var endpoint = URLComponents(string: provider == .podcastIndex ? "https://api.podcastindex.org/search" : "https://itunes.apple.com/search")!
        endpoint.queryItems = [.init(name: "term", value: query)]
        if provider == .apple {
            endpoint.queryItems! += [.init(name: "media", value: "podcast"), .init(name: "entity", value: "podcast"), .init(name: "limit", value: "50")]
        }
        var request = URLRequest(url: endpoint.url!); request.timeoutInterval = 20
        request.setValue("Macarok/0.1.0 (https://github.com/armateurlabs/macarok)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try Task.checkCancellation()
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        if response.statusCode == 429 || response.statusCode == 503 {
            let retry = Self.retryDelay(response, now: now())
            nextRequest[provider] = max(nextRequest[provider] ?? .distantPast, now().addingTimeInterval(retry))
            throw PodcastDirectoryError.throttled(retry)
        }
        guard response.statusCode == 200 else { throw SourceNetworkError.httpStatus(response.statusCode) }
        guard data.count <= 4 * 1_024 * 1_024 else { throw RadioError.invalidResponse }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw RadioError.invalidResponse }
        var seen: Set<String> = []
        let results = payload.results.compactMap { row -> PodcastDirectoryResult? in
            guard let text = row.feedUrl, let feed = try? RadioError.validatedURL(text), seen.insert(feed.absoluteString).inserted else { return nil }
            return .init(id: StableID.make(provider.rawValue, feed.absoluteString), title: row.collectionName ?? row.trackName ?? "Untitled Podcast",
                         author: row.artistName ?? "", feedURL: feed,
                         artworkURL: (row.artworkUrl600 ?? row.artworkUrl100).flatMap { try? RadioError.validatedURL($0) }, provider: provider)
        }
        let bounded = Array(results.prefix(50)); cache[key] = (now(), bounded)
        if cache.count > 100 {
            cache = cache.filter { now().timeIntervalSince($0.value.0) < 600 }
            for entry in cache.sorted(by: { $0.value.0 < $1.value.0 }).prefix(max(0, cache.count - 100)) { cache.removeValue(forKey: entry.key) }
        }
        return bounded
    }

    private static func retryDelay(_ response: HTTPURLResponse, now: Date) -> Double {
        if let raw = response.value(forHTTPHeaderField: "Retry-After"), let delay = Double(raw), delay.isFinite { return min(86_400, max(1, delay)) }
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let raw = response.value(forHTTPHeaderField: "Retry-After"), let until = date.date(from: raw) { return min(86_400, max(1, until.timeIntervalSince(now))) }
        return 30
    }
    private struct Payload: Decodable { let results: [Row] }
    private struct Row: Decodable {
        let collectionName: String?; let trackName: String?; let artistName: String?; let feedUrl: String?
        let artworkUrl600: String?; let artworkUrl100: String?
    }
}

public enum PodcastDirectoryError: LocalizedError {
    case throttled(Double)
    public var errorDescription: String? {
        switch self { case .throttled(let delay): "The podcast directory is busy. Try again in \(Int(min(86_400, max(1, delay)))) seconds." }
    }
}
