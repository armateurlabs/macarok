import Foundation

public struct ICYTitleUpdate: Sendable, Equatable {
    public let audioOffset: UInt64
    public let title: String
}

/// Incremental ICY framing, independent of network chunk boundaries.
public struct ICYMetadataDecoder: Sendable {
    private let interval: Int
    private var remainingAudio: Int
    private var remainingMetadata: Int?
    private var metadata = Data()
    private var audioOffset: UInt64 = 0

    public init(interval: Int) throws {
        guard (1...16 * 1_024 * 1_024).contains(interval) else { throw RadioError.invalidResponse }
        self.interval = interval; remainingAudio = interval
    }

    public mutating func consume(_ data: Data) -> (audio: Data, updates: [ICYTitleUpdate]) {
        var audio = Data(); audio.reserveCapacity(data.count)
        var updates: [ICYTitleUpdate] = []
        var cursor = data.startIndex
        while cursor < data.endIndex {
            if remainingAudio > 0 {
                let count = min(remainingAudio, data.distance(from: cursor, to: data.endIndex))
                let end = data.index(cursor, offsetBy: count)
                audio.append(contentsOf: data[cursor..<end])
                remainingAudio -= count; audioOffset += UInt64(count); cursor = end
            } else if let remaining = remainingMetadata {
                let count = min(remaining, data.distance(from: cursor, to: data.endIndex))
                let end = data.index(cursor, offsetBy: count)
                metadata.append(contentsOf: data[cursor..<end]); remainingMetadata = remaining - count; cursor = end
                if remaining == count {
                    if let title = Self.title(from: metadata) { updates.append(.init(audioOffset: audioOffset, title: title)) }
                    metadata.removeAll(keepingCapacity: true); remainingMetadata = nil; remainingAudio = interval
                }
            } else {
                let count = Int(data[cursor]) * 16
                cursor = data.index(after: cursor)
                if count == 0 { remainingAudio = interval }
                else { remainingMetadata = count }
            }
        }
        return (audio, updates)
    }

    private static func title(from data: Data) -> String? {
        let bytes = data.prefix { $0 != 0 }
        guard let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1),
              let key = text.range(of: "StreamTitle=", options: .caseInsensitive) else { return nil }
        var value = text[key.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if let quote = value.first, quote == "'" || quote == "\"" {
            value.removeFirst()
            if let end = closingQuote(in: value, quote: quote) { value = String(value[..<end]) }
            else if value.last == quote { value.removeLast() }
        } else if let end = value.firstIndex(of: ";") { value = String(value[..<end]) }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The value ends at the first quote and semicolon followed by the end or another `Key=`, such as
    /// `StreamUrl=`; apostrophes inside the title, as in `Don't Stop`, are kept.
    private static func closingQuote(in value: String, quote: Character) -> String.Index? {
        var search = value.startIndex
        while let match = value.range(of: String(quote) + ";", range: search..<value.endIndex) {
            let rest = value[match.upperBound...].drop { $0.isWhitespace }
            let key = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if rest.isEmpty || (!key.isEmpty && rest.dropFirst(key.count).first == "=") { return match.lowerBound }
            search = match.upperBound
        }
        return nil
    }
}
