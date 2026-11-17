import Foundation

public enum LyricsSource: String, Codable, CaseIterable, Sendable {
    case embedded, sidecar, openSubsonic, lrclib, manual

    public var title: String {
        switch self {
        case .embedded: "Embedded lyrics"
        case .sidecar: "Local lyrics file"
        case .openSubsonic: "Music server"
        case .lrclib: "LRCLIB"
        case .manual: "Your lyrics"
        }
    }
}

public struct LyricsLine: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var startTime: Double
    public var text: String

    public init(id: String = UUID().uuidString, startTime: Double, text: String) {
        self.id = id; self.startTime = startTime; self.text = text
    }
}

public struct LyricsDocument: Codable, Equatable, Sendable {
    public var plainText: String
    public var originalLRC: String?
    public var lines: [LyricsLine]
    public var source: LyricsSource
    public var providerID: String?
    public var isInstrumental: Bool

    public init(plainText: String = "", originalLRC: String? = nil, lines: [LyricsLine] = [],
                source: LyricsSource, providerID: String? = nil, isInstrumental: Bool = false) {
        self.lines = lines.filter { $0.startTime.isFinite }.enumerated().sorted {
            $0.element.startTime == $1.element.startTime ? $0.offset < $1.offset : $0.element.startTime < $1.element.startTime
        }.map(\.element)
        self.plainText = plainText.isEmpty ? self.lines.map(\.text).joined(separator: "\n") : plainText
        self.originalLRC = originalLRC; self.source = source
        self.providerID = providerID; self.isInstrumental = isInstrumental
    }

    public var isSynced: Bool { !lines.isEmpty }
    public var hasContent: Bool { isInstrumental || !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || lines.contains { !$0.text.isEmpty } }
    /// Timings already include their source offset. Serialization therefore omits offset tags.
    public var lrcText: String? { LRCParser.serialize(self) }

    public func sliced(from start: Double, to end: Double?) -> LyricsDocument {
        let selected = lines.filter { line in line.startTime >= start && (end.map { line.startTime < $0 } ?? true) }
            .map { LyricsLine(id: $0.id, startTime: $0.startTime - start, text: $0.text) }
        return LyricsDocument(lines: selected, source: source, providerID: providerID, isInstrumental: isInstrumental)
    }
}

public struct LyricsLookupQuery: Sendable, Equatable {
    public var sourceID: String
    public var trackID: String
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double

    public init(sourceID: String, trackID: String, title: String, artist: String, album: String, duration: Double) {
        self.sourceID = sourceID; self.trackID = trackID; self.title = title; self.artist = artist
        self.album = album; self.duration = duration.isFinite ? max(0, duration) : 0
    }

    public init(track: TrackRecord) {
        self.init(sourceID: track.sourceID, trackID: track.id, title: track.title, artist: track.artist, album: track.album,
                  duration: track.endTime.map { max(0, $0 - (track.startTime ?? 0)) } ?? track.duration)
    }

    /// The value with surrounding whitespace removed, or nil for missing-metadata placeholders such as "[Unknown Album]".
    public static func meaningful(_ value: String) -> String? { LyricsMatching.meaningful(value) }

    public var fingerprint: String {
        let boundedDuration = duration.isFinite ? min(1_000_000_000, max(0, duration)) : 0
        return StableID.make(sourceID, trackID, title, artist, album, String(Int((boundedDuration * 1_000).rounded())))
    }
}

public struct LyricsCandidate: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double
    public var document: LyricsDocument

    public init(id: String, title: String, artist: String, album: String, duration: Double, document: LyricsDocument) {
        self.id = id; self.title = title; self.artist = artist; self.album = album; self.duration = duration; self.document = document
    }
}

public enum LyricsLookupResult: Codable, Equatable, Sendable {
    case found(LyricsDocument)
    case instrumental(LyricsDocument)
    case notFound

    public var document: LyricsDocument? {
        switch self { case .found(let value), .instrumental(let value): value; case .notFound: nil }
    }

    public static func from(_ document: LyricsDocument) -> LyricsLookupResult {
        document.isInstrumental ? .instrumental(document) : .found(document)
    }
}

public enum LyricsError: LocalizedError, Sendable {
    case invalidQuery(String)
    case invalidDocument(String)
    case invalidResponse
    case httpStatus(Int)
    case rateLimited(retryAfter: TimeInterval)
    case unavailable(retryAfter: TimeInterval?)

    public var retryAfter: TimeInterval? {
        switch self { case .rateLimited(let value): value; case .unavailable(let value): value; default: nil }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidQuery(let value), .invalidDocument(let value): value
        case .invalidResponse: "The lyrics service returned an invalid response."
        case .httpStatus(let status): "The lyrics service returned HTTP \(status)."
        case .rateLimited(let seconds):
            seconds.isFinite && (0...86_400).contains(seconds)
                ? "The lyrics service is busy. Try again in \(Int(ceil(seconds))) seconds."
                : "The lyrics service is busy. Try again later."
        case .unavailable: "The lyrics service is temporarily unavailable. Try again later."
        }
    }
}

public enum LRCParser {
    private static let timestamp = try! NSRegularExpression(pattern: #"^\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#)
    private static let metadata = try! NSRegularExpression(pattern: #"^\[([a-zA-Z][a-zA-Z0-9]*):(.*)\]\s*$"#)

    public static func parse(_ text: String, source: LyricsSource = .sidecar, providerID: String? = nil) -> LyricsDocument {
        let rawLines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")).components(separatedBy: "\n")
        var offset = 0.0
        var timed: [(Double, String)] = []
        var plain: [String] = []
        for raw in rawLines {
            var remaining = raw.trimmingCharacters(in: .whitespaces)
            let original = remaining as NSString
            if let match = metadata.firstMatch(in: remaining, range: NSRange(location: 0, length: original.length)) {
                let key = original.substring(with: match.range(at: 1)).lowercased()
                if key == "offset", let milliseconds = Double(original.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)), milliseconds.isFinite { offset = milliseconds / 1_000 }
                continue
            }
            var times: [Double] = []
            while true {
                let value = remaining as NSString
                guard let match = timestamp.firstMatch(in: remaining, range: NSRange(location: 0, length: value.length)),
                      let minutes = Double(value.substring(with: match.range(at: 1))),
                      let seconds = Double(value.substring(with: match.range(at: 2))), seconds < 60 else { break }
                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound {
                    let digits = value.substring(with: match.range(at: 3))
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                times.append(minutes * 60 + seconds + fraction)
                remaining = value.substring(from: match.range.length)
            }
            if times.isEmpty { plain.append(raw) }
            else { timed.append(contentsOf: times.map { ($0, remaining.trimmingCharacters(in: .whitespaces)) }) }
        }
        let lines = timed.enumerated().map { index, value in
            LyricsLine(id: StableID.make(String(index), String(value.0), value.1), startTime: value.0 - offset, text: value.1)
        }
        return LyricsDocument(plainText: lines.isEmpty ? plain.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) : "",
                              originalLRC: lines.isEmpty ? nil : text, lines: lines, source: source, providerID: providerID)
    }

    public static func serialize(_ document: LyricsDocument) -> String? {
        guard !document.lines.isEmpty else { return nil }
        return document.lines.map { line in
            let milliseconds = Int((min(1_000_000_000, max(0, line.startTime)) * 1_000).rounded())
            return String(format: "[%02d:%02d.%03d]", milliseconds / 60_000, milliseconds / 1_000 % 60, milliseconds % 1_000) + line.text
        }.joined(separator: "\n") + "\n"
    }
}

extension String {
    /// Text as it should be displayed: control characters other than tabs and line breaks, and soft
    /// hyphens, are removed. Providers sometimes mark hyphenation points with them, and macOS draws
    /// those characters as missing-glyph boxes in the middle of words.
    public var removingInvisibleControls: String {
        func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
            scalar.value == 0xAD || (scalar.properties.generalCategory == .control && scalar != "\n" && scalar != "\t")
        }
        guard unicodeScalars.contains(where: isInvisible) else { return self }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: unicodeScalars.filter { !isInvisible($0) })
        return String(result)
    }
}
