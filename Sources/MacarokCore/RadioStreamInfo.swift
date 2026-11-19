import Foundation

/// What a station announces about itself in its stream's `icy-*` / `ice-*` response headers.
public struct RadioStreamInfo: Sendable, Equatable {
    public var name: String?
    public var genre: String?
    public var description: String?
    public var homepage: URL?
    public var bitrate: Int?
    public var sampleRate: Int?
    public var contentType: String?

    public init(name: String? = nil, genre: String? = nil, description: String? = nil, homepage: URL? = nil,
                bitrate: Int? = nil, sampleRate: Int? = nil, contentType: String? = nil) {
        self.name = name; self.genre = genre; self.description = description; self.homepage = homepage
        self.bitrate = bitrate; self.sampleRate = sampleRate; self.contentType = contentType
    }

    public init(response: HTTPURLResponse) {
        func header(_ name: String) -> String? { Self.meaningful(response.value(forHTTPHeaderField: name)) }
        func positive(_ value: Int?) -> Int? { value.flatMap { $0 > 0 ? $0 : nil } }
        // Icecast's ice-audio-info carries "ice-bitrate=128;ice-samplerate=44100;ice-channels=2".
        var audioInfo: [String: String] = [:]
        for pair in (response.value(forHTTPHeaderField: "ice-audio-info") ?? "").split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { audioInfo[parts[0].lowercased()] = parts[1] }
        }
        // Some servers list several bitrates ("128,64"); the first is the stream's.
        let icyBitrate = header("icy-br")?.split(separator: ",").first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let iceBitrate = audioInfo["ice-bitrate"].flatMap(Double.init).map { Int($0) }
        self.init(name: header("icy-name"), genre: header("icy-genre"), description: header("icy-description"),
                  homepage: header("icy-url").flatMap(Self.webURL),
                  bitrate: positive(icyBitrate ?? iceBitrate),
                  sampleRate: positive(header("icy-sr").flatMap { Int($0) } ?? audioInfo["ice-samplerate"].flatMap { Int($0) }),
                  contentType: header("Content-Type")?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    public var isEmpty: Bool { self == RadioStreamInfo() }

    /// Server defaults such as Icecast's "Unspecified description" say nothing about the station.
    static func meaningful(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let placeholders: Set<String> = ["-", "n/a", "na", "none", "null", "no name", "unspecified", "unspecified name",
                                         "unspecified description", "this is my server description", "stream description",
                                         "stream name", "various", "default genre"]
        return placeholders.contains(value.lowercased()) ? nil : value
    }

    static func webURL(_ text: String) -> URL? {
        let candidate = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: candidate), ["http", "https"].contains(url.scheme?.lowercased()),
              url.host?.contains(".") == true, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
