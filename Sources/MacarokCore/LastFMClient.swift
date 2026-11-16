import CryptoKit
import Foundation
import Security

public struct LastFMAppCredentials: Codable, Sendable, Equatable {
    public var apiKey: String
    public var sharedSecret: String
    public init(apiKey: String, sharedSecret: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sharedSecret = sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var isValid: Bool {
        [apiKey, sharedSecret].allSatisfy { $0.count == 32 && $0.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) } }
    }
}

public struct LastFMSession: Codable, Sendable, Equatable {
    public var username: String
    public var key: String
    public init(username: String, key: String) { self.username = username; self.key = key }
}

public struct LastFMCredentialRecord: Codable, Sendable, Equatable {
    public var application: LastFMAppCredentials
    public var session: LastFMSession?
    public init(application: LastFMAppCredentials, session: LastFMSession? = nil) {
        self.application = application; self.session = session
    }
    public var accountID: String? { session.map { StableID.make(application.apiKey, $0.username.lowercased()) } }
}

public protocol LastFMCredentialStorage: Sendable {
    func load() throws -> LastFMCredentialRecord?
    func save(_ credentials: LastFMCredentialRecord) throws
    func delete() throws
}

public struct LastFMKeychainStore: LastFMCredentialStorage {
    private let service: String
    public init(service: String = "labs.armateur.Macarok.lastfm") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "personal-api-account"]
    }
    public func load() throws -> LastFMCredentialRecord? {
        var query = query
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SourceNetworkError.keychain(status) }
        guard let data = result as? Data else { throw LastFMError.invalidResponse }
        return try JSONDecoder().decode(LastFMCredentialRecord.self, from: data)
    }
    public func save(_ credentials: LastFMCredentialRecord) throws {
        let data = try JSONEncoder().encode(credentials)
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

public struct LastFMTrackSnapshot: Codable, Sendable, Equatable {
    public var sourceID: String
    public var trackID: String
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String
    public var duration: Double
    public var trackNumber: Int?
    public init(track: TrackRecord, duration: Double? = nil) {
        sourceID = track.sourceID; trackID = track.id; title = track.title; artist = track.artist
        album = track.album; albumArtist = track.albumArtist; trackNumber = track.trackNumber
        let logical = track.endTime.map { max(0, $0 - (track.startTime ?? 0)) } ?? track.duration
        let value = duration ?? logical
        self.duration = value.isFinite ? max(0, value) : 0
    }
    public var isEligible: Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !title.isEmpty && !artist.isEmpty && !["unknown track", "unknown title"].contains(title) && artist != "unknown artist"
    }
}

public struct LastFMSubmission: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var track: LastFMTrackSnapshot
    public var startedAt: Date
    public init(id: String = UUID().uuidString, track: LastFMTrackSnapshot, startedAt: Date) {
        self.id = id; self.track = track; self.startedAt = startedAt
    }
}

public struct LastFMSubmissionOutcome: Sendable, Equatable {
    public var id: String
    public var ignoredCode: Int
    public var message: String
    public init(id: String, ignoredCode: Int, message: String) { self.id = id; self.ignoredCode = ignoredCode; self.message = message }
}

public enum LastFMError: LocalizedError, Sendable {
    case invalidConfiguration
    case invalidResponse
    case api(code: Int, message: String)
    case http(status: Int, retryAfter: TimeInterval?)
    public var isInvalidSession: Bool { if case .api(9, _) = self { true } else { false } }
    public var isRetryable: Bool {
        switch self {
        case .api(let code, _): [11, 16, 29].contains(code)
        case .http(let status, _): status == 408 || status == 429 || status >= 500
        case .invalidResponse: true
        default: false
        }
    }
    public var retryAfter: TimeInterval? { if case .http(_, let value) = self { value } else { nil } }
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Enter your 32-character Last.fm API key and shared secret."
        case .invalidResponse: "Last.fm returned an invalid response. Your pending scrobbles have been retained."
        case .api(9, _): "Your Last.fm session has expired or been revoked. Connect again to submit pending scrobbles."
        case .api(14, _): "Approve access in your browser before completing the connection."
        case .api(15, _): "The authorization token expired. Start the connection again."
        case .api(let code, _): "Last.fm could not complete the request (API error \(code))."
        case .http(let status, _): "Last.fm returned HTTP \(status)."
        }
    }
}

/// Uses only personal API credentials and standard HTTPS trust, independently of music servers.
public actor LastFMClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let credentials: LastFMAppCredentials
    private let transport: Transport
    private let now: @Sendable () -> Date
    private var blockedUntil: Date?
    private var occupied = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    public init(credentials: LastFMAppCredentials, transport: Transport? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials; self.now = now
        let session = URLSession(configuration: .ephemeral)
        self.transport = transport ?? { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw LastFMError.invalidResponse }
            return (data, response)
        }
    }

    public func requestToken() async throws -> String {
        let value = try await request(method: "auth.getToken")
        guard let token = value["token"] as? String, !token.isEmpty else { throw LastFMError.invalidResponse }
        return token
    }

    public func session(token: String) async throws -> LastFMSession {
        let value = try await request(method: "auth.getSession", parameters: ["token": token])
        guard let session = value["session"] as? [String: Any], let name = session["name"] as? String,
              let key = session["key"] as? String, !name.isEmpty, !key.isEmpty else { throw LastFMError.invalidResponse }
        return LastFMSession(username: name, key: key)
    }

    public func nowPlaying(track: LastFMTrackSnapshot, session: LastFMSession) async throws {
        _ = try await request(method: "track.updateNowPlaying", parameters: parameters(for: track), session: session)
    }

    public func scrobble(_ entries: [LastFMSubmission], session: LastFMSession) async throws -> [LastFMSubmissionOutcome] {
        guard !entries.isEmpty, entries.count <= 50 else { throw LastFMError.invalidResponse }
        var parameters: [String: String] = [:]
        for (index, entry) in entries.enumerated() {
            for (name, value) in self.parameters(for: entry.track) { parameters["\(name)[\(index)]"] = value }
            let seconds = entry.startedAt.timeIntervalSince1970
            guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) else { throw LastFMError.invalidResponse }
            parameters["timestamp[\(index)]"] = String(Int64(seconds.rounded(.down)))
        }
        let value = try await request(method: "track.scrobble", parameters: parameters, session: session)
        guard let container = value["scrobbles"] as? [String: Any] else { throw LastFMError.invalidResponse }
        let rows: [[String: Any]]
        if let array = container["scrobble"] as? [[String: Any]] { rows = array }
        else if let single = container["scrobble"] as? [String: Any] { rows = [single] }
        else { throw LastFMError.invalidResponse }
        guard rows.count == entries.count else { throw LastFMError.invalidResponse }
        return try zip(entries, rows).map { entry, row in
            guard let ignored = row["ignoredMessage"] as? [String: Any],
                  let code = Self.integer(ignored["code"]) else { throw LastFMError.invalidResponse }
            return LastFMSubmissionOutcome(id: entry.id, ignoredCode: code, message: ignored["#text"] as? String ?? "")
        }
    }

    /// Listening-based similar tracks. An unknown track is an empty result rather than an error.
    public func similarTracks(artist: String, title: String, limit: Int = 100) async throws -> [SimilarTrack] {
        let value: [String: Any]
        do {
            value = try await request(method: "track.getSimilar", parameters: ["artist": artist, "track": title,
                                                                                 "autocorrect": "1", "limit": String(limit)])
        } catch LastFMError.api(code: 6, _) { return [] }
        return Self.list((value["similartracks"] as? [String: Any])?["track"]).compactMap { item in
            guard let name = item["name"] as? String, let artist = (item["artist"] as? [String: Any])?["name"] as? String else { return nil }
            return SimilarTrack(artist: artist, title: name, score: Self.number(item["match"]) ?? 0)
        }
    }

    /// Listening-based similar artists. An unknown artist is an empty result rather than an error.
    public func similarArtists(artist: String, limit: Int = 60) async throws -> [SimilarArtist] {
        let value: [String: Any]
        do {
            value = try await request(method: "artist.getSimilar", parameters: ["artist": artist, "autocorrect": "1", "limit": String(limit)])
        } catch LastFMError.api(code: 6, _) { return [] }
        return Self.list((value["similarartists"] as? [String: Any])?["artist"]).compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return SimilarArtist(name: name, score: Self.number(item["match"]) ?? 0)
        }
    }

    /// Last.fm returns a lone object instead of a one-element array.
    private static func list(_ value: Any?) -> [[String: Any]] {
        if let values = value as? [[String: Any]] { return values }
        return (value as? [String: Any]).map { [$0] } ?? []
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        return (value as? String).flatMap(Double.init)
    }

    public static func signature(parameters: [String: String], secret: String) -> String {
        let input = parameters.keys.filter { !["api_sig", "format", "callback"].contains($0) }.sorted()
            .map { $0 + parameters[$0]! }.joined() + secret
        return Insecure.MD5.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func parameters(for track: LastFMTrackSnapshot) -> [String: String] {
        var result = ["artist": track.artist, "track": track.title]
        if !track.album.isEmpty, track.album.lowercased() != "unknown album" { result["album"] = track.album }
        if !track.albumArtist.isEmpty { result["albumArtist"] = track.albumArtist }
        if track.duration.isFinite, track.duration > 0, track.duration < Double(Int32.max) { result["duration"] = String(Int(track.duration.rounded())) }
        if let number = track.trackNumber, number > 0 { result["trackNumber"] = String(number) }
        return result
    }

    private func request(method: String, parameters: [String: String] = [:], session: LastFMSession? = nil) async throws -> [String: Any] {
        guard credentials.isValid else { throw LastFMError.invalidConfiguration }
        try Task.checkCancellation()
        var values = parameters
        values["method"] = method; values["api_key"] = credentials.apiKey
        if let session { values["sk"] = session.key }
        values["api_sig"] = Self.signature(parameters: values, secret: credentials.sharedSecret)
        values["format"] = "json"
        var request = URLRequest(url: URL(string: "https://ws.audioscrobbler.com/2.0/")!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Macarok/0.1.0", forHTTPHeaderField: "User-Agent")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(values.keys.sorted().map { name in
            name.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + values[name]!.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        if let blockedUntil, blockedUntil > now() {
            throw LastFMError.http(status: 429, retryAfter: blockedUntil.timeIntervalSince(now()))
        }
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        let retry = Self.retryAfter(response, now: now())
        guard data.count <= 2 * 1_024 * 1_024 else { throw LastFMError.invalidResponse }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if response.statusCode == 429 || Self.integer(body?["error"]) == 29 {
            blockedUntil = now().addingTimeInterval(max(1, retry ?? 60))
        }
        if let code = Self.integer(body?["error"]) {
            if [11, 16, 29].contains(code), retry != nil, response.statusCode == 429 || response.statusCode >= 500 {
                throw LastFMError.http(status: response.statusCode, retryAfter: retry)
            }
            throw LastFMError.api(code: code, message: body?["message"] as? String ?? "")
        }
        guard (200..<300).contains(response.statusCode) else { throw LastFMError.http(status: response.statusCode, retryAfter: retry) }
        guard let body else { throw LastFMError.invalidResponse }
        return body
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        return (value as? String).flatMap(Int.init)
    }

    private static func retryAfter(_ response: HTTPURLResponse, now: Date) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(value), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
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
        if waiters.isEmpty { occupied = false } else { waiters.removeFirst().1.resume() }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
}
