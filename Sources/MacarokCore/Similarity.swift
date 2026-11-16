import Foundation
import GRDB

public struct SimilarTrack: Codable, Sendable, Equatable {
    public var artist: String
    public var title: String
    /// Provider similarity, normalized to 0...1.
    public var score: Double
    public init(artist: String, title: String, score: Double) { self.artist = artist; self.title = title; self.score = score }
}

public struct SimilarArtist: Codable, Sendable, Equatable {
    public var name: String
    /// Provider similarity, normalized to 0...1.
    public var score: Double
    public init(name: String, score: Double) { self.name = name; self.score = score }
}

/// A listening-based similarity service. Providers receive only artist names and titles.
public protocol SimilarityProvider: Sendable {
    var name: String { get }
    func similarTracks(artist: String, title: String) async throws -> [SimilarTrack]
    func similarArtists(artist: String) async throws -> [SimilarArtist]
}

public enum SimilarityError: LocalizedError, Equatable {
    case noProviders
    case noMatches
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .noProviders: "No similarity service is available."
        case .noMatches: "No similar tracks were found in your library."
        case .unavailable(let detail): detail
        }
    }
}

public struct LastFMSimilarityProvider: SimilarityProvider {
    public let client: LastFMClient
    public let name = "lastfm"
    public init(client: LastFMClient) { self.client = client }
    public func similarTracks(artist: String, title: String) async throws -> [SimilarTrack] {
        try await client.similarTracks(artist: artist, title: title)
    }
    public func similarArtists(artist: String) async throws -> [SimilarArtist] {
        try await client.similarArtists(artist: artist)
    }
}

/// ListenBrainz similar artists, computed from listening sessions. Artist names are resolved to MusicBrainz
/// identifiers first. Both services are public and need no account.
public actor ListenBrainzClient: SimilarityProvider {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public nonisolated let name = "listenbrainz"
    static let algorithm = "session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30"
    private let transport: Transport
    private let musicBrainzSpacing: TimeInterval
    private var nextMusicBrainzRequest = Date.distantPast
    private var artistIDs: [String: String?] = [:]

    public init(transport: Transport? = nil, musicBrainzSpacing: TimeInterval = 1.1) {
        self.musicBrainzSpacing = musicBrainzSpacing
        let session = URLSession(configuration: .ephemeral)
        self.transport = transport ?? { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw SimilarityError.unavailable("ListenBrainz returned an invalid response.") }
            return (data, response)
        }
    }

    public nonisolated func similarTracks(artist: String, title: String) async throws -> [SimilarTrack] { [] }

    public func similarArtists(artist: String) async throws -> [SimilarArtist] {
        guard let id = try await artistID(named: artist) else { return [] }
        var components = URLComponents(string: "https://labs.api.listenbrainz.org/similar-artists/json")!
        components.queryItems = [.init(name: "artist_mbids", value: id), .init(name: "algorithm", value: Self.algorithm)]
        let data = try await get(components.url!, service: "ListenBrainz")
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SimilarityError.unavailable("ListenBrainz returned an invalid response.")
        }
        let artists = items.compactMap { item -> SimilarArtist? in
            guard let name = item["name"] as? String, (item["artist_mbid"] as? String) != id else { return nil }
            return SimilarArtist(name: name, score: (item["score"] as? NSNumber)?.doubleValue ?? 0)
        }
        let top = artists.map(\.score).max() ?? 0
        return top > 0 ? artists.map { SimilarArtist(name: $0.name, score: $0.score / top) } : artists
    }

    /// The MusicBrainz artist whose name matches, cached for the lifetime of the client.
    public func artistID(named name: String) async throws -> String? {
        let key = LyricsMatching.folded(name)
        guard !key.isEmpty else { return nil }
        if let cached = artistIDs[key] { return cached }
        let scheduled = max(Date(), nextMusicBrainzRequest)
        nextMusicBrainzRequest = scheduled.addingTimeInterval(musicBrainzSpacing)
        let delay = scheduled.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/artist/")!
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        components.queryItems = [.init(name: "query", value: "artist:\"\(escaped)\""), .init(name: "fmt", value: "json"), .init(name: "limit", value: "5")]
        let data = try await get(components.url!, service: "MusicBrainz")
        guard let artists = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["artists"] as? [[String: Any]] else {
            throw SimilarityError.unavailable("MusicBrainz returned an invalid response.")
        }
        let match = artists.first { ($0["name"] as? String).map(LyricsMatching.folded) == key }
            ?? artists.first { ($0["score"] as? NSNumber)?.intValue == 100 }
        let id = match?["id"] as? String
        artistIDs[key] = .some(id)
        return id
    }

    private func get(_ url: URL, service: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Macarok ( https://github.com/armateurlabs/macarok )", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw SimilarityError.unavailable("\(service) returned HTTP \(response.statusCode).")
        }
        return data
    }
}

public enum SimilarityCacheStorage {
    public static func registerMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("similarity-cache-v1") { db in
            try db.execute(sql: """
                CREATE TABLE similarityCache (
                    key TEXT PRIMARY KEY NOT NULL,
                    payload BLOB NOT NULL,
                    expiresAt DOUBLE NOT NULL
                );
                """)
        }
    }
}

extension LibraryStore {
    public func cachedSimilarity(key: String, now: Date = Date()) throws -> Data? {
        try database.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM similarityCache WHERE key = ? AND expiresAt > ?",
                              arguments: [key, now.timeIntervalSince1970])
        }
    }

    public func saveSimilarity(_ payload: Data, key: String, expiresAt: Date) throws {
        try database.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO similarityCache (key, payload, expiresAt) VALUES (?, ?, ?)",
                           arguments: [key, payload, expiresAt.timeIntervalSince1970])
        }
    }
}

/// Keeps provider answers in SQLite: a week for results, a day for empty answers. Errors are not cached.
public struct CachedSimilarityProvider: SimilarityProvider {
    public let base: any SimilarityProvider
    public let store: LibraryStore
    public let now: @Sendable () -> Date
    public var name: String { base.name }

    public init(_ base: any SimilarityProvider, store: LibraryStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.base = base; self.store = store; self.now = now
    }

    public func similarTracks(artist: String, title: String) async throws -> [SimilarTrack] {
        try await cached("\(name).tracks|\(LyricsMatching.folded(artist))|\(LyricsMatching.folded(title))") {
            try await base.similarTracks(artist: artist, title: title)
        }
    }

    public func similarArtists(artist: String) async throws -> [SimilarArtist] {
        try await cached("\(name).artists|\(LyricsMatching.folded(artist))") { try await base.similarArtists(artist: artist) }
    }

    private func cached<Value: Codable>(_ key: String, fetch: () async throws -> [Value]) async throws -> [Value] {
        if let data = try? store.cachedSimilarity(key: key, now: now()), let value = try? JSONDecoder().decode([Value].self, from: data) {
            return value
        }
        let value = try await fetch()
        let lifetime: TimeInterval = value.isEmpty ? 86_400 : 7 * 86_400
        if let data = try? JSONEncoder().encode(value) { try? store.saveSimilarity(data, key: key, expiresAt: now().addingTimeInterval(lifetime)) }
        return value
    }
}

/// Library tracks indexed by artist and title spelling, so provider names can be matched without identifiers.
public struct SimilarityLibrary: Sendable {
    public let tracks: [TrackRecord]
    private let byArtist: [String: [Int]]
    private let byTitle: [String: [Int]]

    public init(tracks: [TrackRecord]) {
        self.tracks = tracks
        var byArtist: [String: [Int]] = [:], byTitle: [String: [Int]] = [:]
        for (index, track) in tracks.enumerated() {
            for artist in Self.artistKeys(track) { byArtist[artist, default: []].append(index) }
            byTitle[LyricsMatching.folded(LyricsMatching.simplifiedTitle(track.title)), default: []].append(index)
        }
        self.byArtist = byArtist; self.byTitle = byTitle
    }

    public var isEmpty: Bool { tracks.isEmpty }

    /// Copies and reissues of one recording share this key, so skipping one excludes the others.
    public static func editionKey(_ track: TrackRecord) -> String {
        let artist = LyricsMatching.artistNames(track.artist).first ?? LyricsMatching.folded(track.artist)
        let editions = LyricsMatching.editions(track.title).sorted().joined(separator: ",")
        return artist + "|" + LyricsMatching.folded(LyricsMatching.simplifiedTitle(track.title)) + "|" + editions
    }

    public static func primaryArtist(_ track: TrackRecord) -> String {
        LyricsMatching.artistNames(track.artist).first ?? LyricsMatching.folded(track.artist)
    }

    /// Tracks by the named artist, including featured credits.
    public func tracks(byArtist name: String) -> [TrackRecord] {
        let keys = LyricsMatching.artistNames(name)
        guard let first = keys.first else { return [] }
        return (byArtist[first] ?? []).map { tracks[$0] }
    }

    /// The same recording: matching artist and title, tolerating version suffixes but not other editions.
    public func tracks(matching artist: String, title: String) -> [TrackRecord] {
        let key = LyricsMatching.folded(LyricsMatching.simplifiedTitle(title))
        return (byTitle[key] ?? []).map { tracks[$0] }.filter {
            LyricsMatching.titleMatches($0.title, title, allowSimplified: true) && LyricsMatching.artistMatches($0.artist, artist)
        }
    }

    private static func artistKeys(_ track: TrackRecord) -> Set<String> {
        Set(LyricsMatching.artistNames(track.artist) + LyricsMatching.artistNames(track.albumArtist).prefix(1))
    }
}

public struct SimilaritySeed: Sendable, Equatable {
    public var artist: String
    public var title: String
    public var weight: Double
    public init(artist: String, title: String, weight: Double = 1) { self.artist = artist; self.title = title; self.weight = weight }
    public init(_ track: TrackRecord, weight: Double = 1) { self.init(artist: track.artist, title: track.title, weight: weight) }
}

public struct SimilarityCandidate: Sendable, Equatable {
    public var track: TrackRecord
    public var score: Double
    public init(track: TrackRecord, score: Double) { self.track = track; self.score = score }
}

/// Combines provider answers into scored library tracks.
public struct SimilarityService: Sendable {
    public let providers: [any SimilarityProvider]
    public init(providers: [any SimilarityProvider]) { self.providers = providers }

    /// Library tracks similar to the seeds, best first, one per recording.
    /// `excluded` contains track identifiers and edition keys.
    public func candidates(for seeds: [SimilaritySeed], in library: SimilarityLibrary,
                           excluding excluded: Set<String> = []) async throws -> [SimilarityCandidate] {
        guard !providers.isEmpty else { throw SimilarityError.noProviders }
        var scores: [String: Double] = [:]
        var tracksByID: [String: TrackRecord] = [:]
        var attempts = 0
        var failures: [Error] = []
        func add(_ track: TrackRecord, _ score: Double) {
            tracksByID[track.id] = track
            scores[track.id, default: 0] += score
        }
        var artistQueries: [String: (name: String, weight: Double)] = [:]
        for seed in seeds {
            let key = LyricsMatching.artistNames(seed.artist).first ?? LyricsMatching.folded(seed.artist)
            artistQueries[key] = (seed.artist, max(artistQueries[key]?.weight ?? 0, seed.weight))
        }
        for seed in seeds {
            try Task.checkCancellation()
            for provider in providers {
                attempts += 1
                do {
                    for similar in try await provider.similarTracks(artist: seed.artist, title: seed.title) {
                        for track in library.tracks(matching: similar.artist, title: similar.title) {
                            add(track, seed.weight * (1 + min(1, max(0, similar.score))))
                        }
                    }
                } catch is CancellationError { throw CancellationError() } catch { failures.append(error) }
            }
        }
        for (_, query) in artistQueries {
            try Task.checkCancellation()
            var merged: [String: (name: String, score: Double)] = [:]
            for provider in providers {
                attempts += 1
                do {
                    for artist in try await provider.similarArtists(artist: query.name) {
                        let key = LyricsMatching.artistNames(artist.name).first ?? LyricsMatching.folded(artist.name)
                        merged[key] = (artist.name, max(merged[key]?.score ?? 0, min(1, max(0, artist.score))))
                    }
                } catch is CancellationError { throw CancellationError() } catch { failures.append(error) }
            }
            for (_, artist) in merged {
                for track in library.tracks(byArtist: artist.name) { add(track, query.weight * 0.6 * artist.score) }
            }
            // The seed artist stays possible, but below similar artists.
            for track in library.tracks(byArtist: query.name) { add(track, query.weight * 0.25) }
        }
        if failures.count == attempts, let first = failures.first { throw first }
        var best: [String: SimilarityCandidate] = [:]
        for (id, score) in scores {
            guard let track = tracksByID[id], !excluded.contains(id) else { continue }
            let edition = SimilarityLibrary.editionKey(track)
            guard !excluded.contains(edition) else { continue }
            let total = score + 0.02 * log1p(Double(max(0, track.playCount)))
            if best[edition].map({ $0.score < total }) ?? true { best[edition] = SimilarityCandidate(track: track, score: total) }
        }
        let result = best.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.track.id < $1.track.id }
        guard !result.isEmpty else { throw SimilarityError.noMatches }
        return result
    }
}

public enum SimilarityRanking {
    /// Best-first order that never repeats an artist back to back when avoidable and limits each artist.
    public static func playlist(_ candidates: [SimilarityCandidate], limit: Int?, perArtist: Int = 4) -> [TrackRecord] {
        var remaining = candidates
        var result: [TrackRecord] = []
        var counts: [String: Int] = [:]
        let maximum = limit.map { max(0, $0) } ?? Int.max
        while result.count < maximum, !remaining.isEmpty {
            let previous = result.last.map(SimilarityLibrary.primaryArtist)
            let allowed = remaining.indices.filter { counts[SimilarityLibrary.primaryArtist(remaining[$0].track), default: 0] < perArtist }
            guard !allowed.isEmpty else { break }
            let index = allowed.first { SimilarityLibrary.primaryArtist(remaining[$0].track) != previous } ?? allowed[0]
            let pick = remaining.remove(at: index)
            counts[SimilarityLibrary.primaryArtist(pick.track), default: 0] += 1
            result.append(pick.track)
        }
        return result
    }

    /// A weighted choice among the best few, preferring another artist than the one just played.
    public static func next<Generator: RandomNumberGenerator>(_ candidates: [SimilarityCandidate], avoidingArtistOf previous: TrackRecord?,
                                                             pool: Int = 6, using generator: inout Generator) -> TrackRecord? {
        let avoided = previous.map(SimilarityLibrary.primaryArtist)
        let preferred = candidates.filter { SimilarityLibrary.primaryArtist($0.track) != avoided }
        let top = Array((preferred.isEmpty ? candidates : preferred).prefix(pool))
        guard !top.isEmpty else { return nil }
        let total = top.reduce(0) { $0 + max(0.0001, $1.score) }
        var target = Double.random(in: 0..<total, using: &generator)
        for candidate in top {
            target -= max(0.0001, candidate.score)
            if target < 0 { return candidate.track }
        }
        return top.last?.track
    }
}
