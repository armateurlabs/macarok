import Foundation

/// A public-service client. Source-server credentials are never used here.
public actor LRCLIBClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    private let baseURL: URL
    private let transport: Transport
    private let sleep: Sleeper
    private let now: @Sendable () -> Date
    private let minimumRequestSpacing: TimeInterval
    private let userAgent: String
    private var lastRequest: Date?
    private var blockedUntil: Date?
    private var occupied = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    public init(baseURL: URL = URL(string: "https://lrclib.net")!,
                userAgent: String = "Macarok/0.1.0 (https://github.com/armateurlabs/macarok)",
                minimumRequestSpacing: TimeInterval = 0.25,
                transport: Transport? = nil, sleep: Sleeper? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL; self.userAgent = userAgent
        self.minimumRequestSpacing = minimumRequestSpacing.isFinite ? max(0, minimumRequestSpacing) : 0.25
        self.now = now
        let session = URLSession(configuration: .ephemeral)
        self.transport = transport ?? { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw LyricsError.invalidResponse }
            return (data, response)
        }
        self.sleep = sleep ?? { seconds in
            if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
        }
    }

    /// Tries the exact edition first, then progressively more lenient spellings. Every accepted result
    /// must still match the title, an artist, the performance type, and (when known) the duration.
    public func lookup(_ query: LyricsLookupQuery) async throws -> LyricsLookupResult {
        guard let title = LyricsMatching.meaningful(query.title) else { return .notFound }
        let artist = LyricsMatching.meaningful(query.artist)
        let album = LyricsMatching.meaningful(query.album)
        let duration = query.duration.isFinite && (1...3600).contains(query.duration) ? query.duration : nil
        if let artist {
            var exact = ["track_name": title, "artist_name": artist]
            if let duration { exact["duration"] = String(duration) }
            for parameters in album.map({ [exact.merging(["album_name": $0]) { $1 }, exact] }) ?? [exact] {
                guard let data = try await request(path: "api/get", parameters: parameters) else { continue }
                let record: Record
                do { record = try JSONDecoder().decode(Record.self, from: data) }
                catch { throw LyricsError.invalidResponse }
                if let candidate = record.candidate,
                   Self.accepts(candidate, title: title, artist: artist, duration: duration, tolerance: 2) {
                    return .from(candidate.document)
                }
            }
        }
        var searches: [[String: String]] = []
        let primary = artist.flatMap { LyricsMatching.artistNames($0).first }
        for (searchTitle, searchArtist) in [(title, artist), (LyricsMatching.simplifiedTitle(title), primary ?? artist)] {
            var parameters = ["track_name": searchTitle]
            if let searchArtist { parameters["artist_name"] = searchArtist }
            if !searches.contains(parameters) { searches.append(parameters) }
        }
        // A title-only search finds entries filed under another artist spelling; artist and duration still filter them.
        if artist != nil, duration != nil { searches.append(["track_name": LyricsMatching.simplifiedTitle(title)]) }
        for parameters in searches {
            guard let data = try await request(path: "api/search", parameters: parameters) else { continue }
            let candidates: [LyricsCandidate]
            do { candidates = try JSONDecoder().decode([Record].self, from: data).compactMap(\.candidate) }
            catch { throw LyricsError.invalidResponse }
            if let best = Self.best(candidates, title: title, artist: artist, duration: duration) { return .from(best.document) }
        }
        return .notFound
    }

    private static func accepts(_ candidate: LyricsCandidate, title: String, artist: String?, duration: Double?,
                                tolerance: Double) -> Bool {
        if let duration, abs(candidate.duration - duration) > tolerance { return false }
        if let artist, !LyricsMatching.artistMatches(candidate.artist, artist) { return false }
        // A simplified title is accepted only when the duration independently confirms the recording.
        return LyricsMatching.titleMatches(candidate.title, title, allowSimplified: duration != nil)
    }

    private static func best(_ candidates: [LyricsCandidate], title: String, artist: String?, duration: Double?) -> LyricsCandidate? {
        guard artist != nil || duration != nil else { return nil }
        return candidates.filter { accepts($0, title: title, artist: artist, duration: duration, tolerance: 3) }
            .min { lhs, rhs in
                func rank(_ value: LyricsCandidate) -> (Int, Int, Double) {
                    (LyricsMatching.folded(value.title) == LyricsMatching.folded(title) ? 0 : 1,
                     value.document.lines.isEmpty ? 1 : 0, duration.map { abs(value.duration - $0) } ?? 0)
                }
                return rank(lhs) < rank(rhs)
            }
    }

    public func search(_ query: LyricsLookupQuery, text: String? = nil) async throws -> [LyricsCandidate] {
        var parameters: [String: String] = [:]
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parameters["q"] = text
        } else {
            guard !query.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LyricsError.invalidQuery("Enter a track title to search for lyrics.")
            }
            parameters["track_name"] = query.title
            // Placeholders such as "[Unknown Album]" would exclude every real result.
            if let artist = LyricsMatching.meaningful(query.artist) { parameters["artist_name"] = artist }
            if let album = LyricsMatching.meaningful(query.album) { parameters["album_name"] = album }
        }
        guard let data = try await request(path: "api/search", parameters: parameters) else { return [] }
        do { return try JSONDecoder().decode([Record].self, from: data).compactMap(\.candidate) }
        catch { throw LyricsError.invalidResponse }
    }

    private func request(path: String, parameters: [String: String]) async throws -> Data? {
        guard ["https", "http"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              var url = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw LyricsError.invalidQuery("The lyrics service address is invalid.")
        }
        url.queryItems = parameters.keys.sorted().map { URLQueryItem(name: $0, value: parameters[$0]) }
        guard let endpoint = url.url else { throw LyricsError.invalidQuery("The lyrics request is invalid.") }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await acquire()
        defer { release() }
        for attempt in 0...1 {
            try Task.checkCancellation()
            while true {
                let earliest = max(lastRequest?.addingTimeInterval(minimumRequestSpacing) ?? .distantPast,
                                   blockedUntil ?? .distantPast)
                let delay = earliest.timeIntervalSince(now())
                guard delay > 0 else { break }
                // Untrusted Retry-After values must never overflow a sleep duration.
                try await sleep(min(delay, 60))
                try Task.checkCancellation()
            }
            try Task.checkCancellation()
            lastRequest = now()
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            switch response.statusCode {
            case 200:
                guard data.count <= 2 * 1_024 * 1_024 else { throw LyricsError.invalidResponse }
                return data
            case 404: return nil
            case 429, 503:
                let fallback: TimeInterval = response.statusCode == 429 ? 5 : 1
                let interval = max(0.25, retryAfter(response) ?? fallback)
                // Persist the cooldown across searches as well as automatic lookups.
                blockedUntil = now().addingTimeInterval(interval + Double.random(in: 0...min(1, interval * 0.3)))
                if attempt == 0, interval <= 3 { continue }
                if response.statusCode == 429 { throw LyricsError.rateLimited(retryAfter: interval) }
                throw LyricsError.unavailable(retryAfter: interval)
            default: throw LyricsError.httpStatus(response.statusCode)
            }
        }
        throw LyricsError.invalidResponse
    }

    private func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(value), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now())) }
    }

    private func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if occupied { waiters.append((id, continuation)) }
                else { occupied = true; continuation.resume() }
            }
        } onCancel: { Task { await self.cancelWaiter(id) } }
    }

    private func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().1.resume() }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }

    private struct Record: Decodable {
        let id: Int
        let trackName: String
        let artistName: String
        let albumName: String
        let duration: Double
        let instrumental: Bool
        let plainLyrics: String?
        let syncedLyrics: String?

        var candidate: LyricsCandidate? {
            guard duration.isFinite, duration >= 0 else { return nil }
            var document: LyricsDocument
            if let syncedLyrics, !syncedLyrics.isEmpty {
                document = LRCParser.parse(syncedLyrics, source: .lrclib, providerID: String(id))
                if let plainLyrics, !plainLyrics.isEmpty { document.plainText = plainLyrics }
            } else { document = LyricsDocument(plainText: plainLyrics ?? "", source: .lrclib, providerID: String(id)) }
            document.isInstrumental = instrumental
            guard document.hasContent else { return nil }
            return LyricsCandidate(id: String(id), title: trackName, artist: artistName,
                                   album: albumName, duration: duration, document: document)
        }
    }
}
