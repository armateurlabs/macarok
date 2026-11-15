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
        for byte in data {
            if remainingAudio > 0 {
                audio.append(byte); remainingAudio -= 1; audioOffset += 1
            } else if let remaining = remainingMetadata {
                metadata.append(byte); remainingMetadata = remaining - 1
                if remaining == 1 {
                    if let title = Self.title(from: metadata) { updates.append(.init(audioOffset: audioOffset, title: title)) }
                    metadata.removeAll(keepingCapacity: true); remainingMetadata = nil; remainingAudio = interval
                }
            } else {
                let count = Int(byte) * 16
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
            if let end = value.range(of: String(quote) + ";", options: .backwards) { value = String(value[..<end.lowerBound]) }
            else if value.last == quote { value.removeLast() }
        } else if let end = value.firstIndex(of: ";") { value = String(value[..<end]) }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
