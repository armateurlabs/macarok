import Foundation

public actor RadioBrowserClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let suppliedMirrors: [URL]?
    private var mirrors: [URL] = []
    private var discoveredAt: Date?
    private var cache: [String: (Date, [RadioStationRecord])] = [:]

    public init(mirrors: [URL]? = nil, transport: Transport? = nil) {
        suppliedMirrors = mirrors
        let session = URLSession(configuration: .ephemeral)
        self.transport = transport ?? { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw RadioError.invalidResponse }
            return (data, response)
        }
    }

    public func search(query: String, country: String = "", language: String = "", tags: String = "") async throws -> [RadioStationRecord] {
        let fields = [query,country,language,tags].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let key = fields.joined(separator: "\u{1f}").lowercased()
        if let value = cache[key], Date().timeIntervalSince(value.0) < 300 { return value.1 }
        var parameters = ["limit":"50", "hidebroken":"true", "order":"clickcount", "reverse":"true"]
        for (name, value) in zip(["name","country","language","tagList"], fields) where !value.isEmpty { parameters[name] = value }
        let data = try await request(path: "json/stations/search", parameters: parameters)
        let rows: [Row]
        do { rows = try JSONDecoder().decode([Row].self, from: data) } catch { throw RadioError.invalidResponse }
        let result = Array(rows.compactMap(\.station).prefix(50)); cache[key] = (Date(), result)
        if cache.count > 100 { cache.removeAll(keepingCapacity: true) }
        return result
    }

    public func station(directoryID: String) async throws -> RadioStationRecord? {
        guard UUID(uuidString: directoryID) != nil else { throw RadioError.invalidResponse }
        let data = try await request(path: "json/stations/byuuid/" + directoryID, parameters: [:])
        return try JSONDecoder().decode([Row].self, from: data).first?.station
    }

    private func request(path: String, parameters: [String: String]) async throws -> Data {
        let endpoints = await availableMirrors()
        var lastError: Error = RadioError.invalidResponse
        for base in endpoints.prefix(3) {
            try Task.checkCancellation()
            var endpoint = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            endpoint.queryItems = parameters.keys.sorted().map { .init(name: $0, value: parameters[$0]) }
            guard let url = endpoint.url else { throw RadioError.invalidURL }
            var request = URLRequest(url: url); request.timeoutInterval = 12
            request.setValue("Macarok/0.1.0 (https://github.com/armateurlabs/macarok)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await transport(request)
                try Task.checkCancellation()
                guard response.statusCode == 200 else { throw SourceNetworkError.httpStatus(response.statusCode) }
                guard data.count <= 4 * 1_024 * 1_024 else { throw RadioError.invalidResponse }
                return data
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
        }
        throw lastError
    }

    private func availableMirrors() async -> [URL] {
        if let suppliedMirrors { return suppliedMirrors }
        if let discoveredAt, Date().timeIntervalSince(discoveredAt) < 3600, !mirrors.isEmpty { return mirrors }
        let discovered = await Task.detached(priority: .utility) {
            Array(Set(Host(name: "all.api.radio-browser.info").addresses.prefix(6).compactMap { address -> URL? in
                guard let name = Host(address: address).name?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                      name.hasSuffix(".api.radio-browser.info") else { return nil }
                return URL(string: "https://" + name)
            })).shuffled()
        }.value
        let fallback = ["de1", "nl1", "at1"].compactMap { URL(string: "https://\($0).api.radio-browser.info") }
        mirrors = discovered.isEmpty ? fallback.shuffled() : discovered
        discoveredAt = Date()
        return mirrors
    }

    private struct Row: Decodable {
        let stationuuid: String; let name: String; let url: String; let url_resolved: String?
        let homepage: String?; let favicon: String?; let country: String?; let language: String?
        let tags: String?; let codec: String?; let bitrate: Int?; let hls: Int?
        var station: RadioStationRecord? {
            guard (try? RadioError.validatedURL(url)) != nil else { return nil }
            return .init(name: name, streamURL: url, resolvedURL: url_resolved.flatMap { (try? RadioError.validatedURL($0)) != nil ? $0 : nil },
                         directoryID: stationuuid, homepage: homepage, artworkURL: favicon,
                         country: country ?? "", language: language ?? "", tags: tags ?? "", codec: codec ?? "",
                         bitrate: bitrate ?? 0, isHLS: hls == 1)
        }
    }
}

public enum RadioStreamResolver {
    /// Resolves wrappers only, without downloading an unbounded audio stream.
    public static func resolve(_ url: URL, transport: SourceTransport, timeout: Duration = .seconds(15)) async throws -> URL {
        let request = RadioResolutionRequest()
        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await resolveWrappers(url, transport: transport, request: request)
                } onCancel: { request.cancel() }
            }
            group.addTask { try await Task.sleep(for: timeout); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func resolveWrappers(_ url: URL, transport: SourceTransport, request activeRequest: RadioResolutionRequest) async throws -> URL {
        var current = try RadioError.validatedURL(url.absoluteString)
        var seen: Set<URL> = []
        for _ in 0..<4 {
            try Task.checkCancellation()
            guard seen.insert(current).inserted else { throw RadioError.playlistLoop }
            if current.pathExtension.lowercased() == "m3u8" { throw RadioError.unsupportedHLS }
            guard ["m3u","pls"].contains(current.pathExtension.lowercased()) else { return current }
            var request = URLRequest(url: current)
            request.timeoutInterval = 15
            let (bytes, response) = try await transport.bytes(for: request)
            activeRequest.install(bytes.task)
            defer { bytes.task.cancel() }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 1_024 * 1_024 else { throw RadioError.invalidResponse }
                data.append(byte)
            }
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
            if text.contains("#EXT-X-") { throw RadioError.unsupportedHLS }
            let base = response.url ?? current
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let candidates: [String]
            if current.pathExtension.lowercased() == "pls" {
                candidates = lines.filter { $0.lowercased().hasPrefix("file") && $0.contains("=") }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    .map { String($0.split(separator: "=", maxSplits: 1).last ?? "") }
            } else { candidates = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") } }
            guard let next = candidates.compactMap({ URL(string: $0, relativeTo: base)?.absoluteURL })
                .first(where: { (try? RadioError.validatedURL($0.absoluteString)) != nil }) else { throw RadioError.emptyPlaylist }
            current = next
        }
        throw RadioError.playlistLoop
    }
}

/// Cancels a trickling body immediately when the overall resolver deadline wins.
private final class RadioResolutionRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func install(_ value: URLSessionTask) {
        lock.lock()
        let cancel = cancelled
        if !cancel { task = value }
        lock.unlock()
        if cancel { value.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = task; self.task = nil; lock.unlock()
        task?.cancel()
    }
}
