import Foundation
import ImageIO
import MacarokCore
import MacarokTagBridge

public enum MetadataError: LocalizedError {
    case unsupported(String)
    case invalidArtwork
    case changedDuringEdit
    case verificationFailed(String)
    case cueTrackNotFound(Int)
    case invalidCUEValue

    public var errorDescription: String? {
        switch self {
        case .unsupported(let message): return message
        case .invalidArtwork: return "Choose a valid image smaller than 32 MB."
        case .changedDuringEdit: return "The file changed while metadata was being saved. Review the new file and try again."
        case .verificationFailed(let key): return "The saved \(key) metadata could not be verified. The original file was preserved."
        case .cueTrackNotFound(let number): return "Track \(number) was not found in the CUE sheet."
        case .invalidCUEValue: return "CUE metadata cannot contain line breaks or null characters."
        }
    }
}

/// Serializes TagLib file access and commits changes using a verified temporary copy.
public enum TagLibMetadataService {
    private static let lock = NSRecursiveLock()

    public static func read(url: URL) throws -> AudioFileMetadata {
        lock.lock()
        defer { lock.unlock() }
        return try autoreleasepool { try readAutoreleased(url: url) }
    }

    private static func readAutoreleased(url: URL) throws -> AudioFileMetadata {
        let document = try readDocument(url: url)
        let properties = document.properties
        func first(_ key: String) -> String? {
            properties[key]?.first.flatMap { $0.isEmpty ? nil : $0 }
        }
        func number(_ key: String) -> Int? {
            first(key).flatMap { Int($0.split(separator: "/", maxSplits: 1).first.map(String.init) ?? $0) }
        }
        let cueText = first("CUESHEET")
        let sampleRate = document.sampleRate > 0 ? document.sampleRate : nil
        let cuePoints = cueText == nil && document.format == "FLAC"
            ? try FLACEmbeddedCUE.read(url: url, sampleRate: sampleRate, properties: properties)
            : nil
        return AudioFileMetadata(
            title: first("TITLE"), artist: first("ARTIST"), albumArtist: first("ALBUMARTIST"),
            album: first("ALBUM"), year: first("DATE").flatMap { Int($0.prefix(4)) },
            genre: properties["GENRE"]?.joined(separator: "; "), trackNumber: number("TRACKNUMBER"),
            discNumber: number("DISCNUMBER"), duration: document.duration > 0 ? document.duration : nil,
            format: document.format, artworkData: document.artworkData,
            artworkMIMEType: document.artworkMIMEType, embeddedCueSheet: cueText,
            sampleRate: sampleRate, channels: document.channels > 0 ? document.channels : nil,
            bitsPerSample: document.bitsPerSample > 0 ? document.bitsPerSample : nil,
            cuePoints: cuePoints
        )
    }

    public static func properties(url: URL) throws -> [String: [String]] {
        lock.lock()
        defer { lock.unlock() }
        return try autoreleasepool { try readDocument(url: url).properties }
    }

    @discardableResult
    public static func write(
        properties: [String: String], artworkData: Data? = nil,
        artworkMIMEType: String? = nil, to url: URL
    ) throws -> AudioFileMetadata {
        lock.lock()
        defer { lock.unlock() }
        guard url.isFileURL else {
            throw MetadataError.unsupported("Writing tags requires access to the original audio file.")
        }
        let original = url.resolvingSymlinksInPath()
        let attributes = try FileFingerprint(url: original)
        var normalized: [String: String] = [:]
        for key in properties.keys.sorted() {
            guard !key.isEmpty, !key.contains("\0"), !(properties[key]?.contains("\0") ?? true) else {
                throw MetadataError.unsupported("Metadata field names and values must not contain null characters.")
            }
            normalized[key.uppercased()] = properties[key]
        }
        var detectedMIME = artworkMIMEType
        if let artworkData {
            guard !artworkData.isEmpty, artworkData.count <= 32 * 1_024 * 1_024,
                  let source = CGImageSourceCreateWithData(artworkData as CFData, nil),
                  CGImageSourceGetCount(source) > 0 else { throw MetadataError.invalidArtwork }
            if artworkData.starts(with: [0x89, 0x50, 0x4E, 0x47]) { detectedMIME = "image/png" }
            else if artworkData.starts(with: [0xFF, 0xD8]) { detectedMIME = "image/jpeg" }
        }
        let temporary = original.deletingLastPathComponent()
            .appendingPathComponent(".macarok-\(UUID().uuidString)")
            .appendingPathExtension(original.pathExtension)
        try FileManager.default.copyItem(at: original, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let message = MCWriteTags(temporary, normalized, artworkData, detectedMIME) {
            throw MetadataError.unsupported(message)
        }
        let verified = try readDocument(url: temporary)
        for (key, value) in normalized {
            let actual = verified.properties[key]?.first ?? ""
            guard actual == value else { throw MetadataError.verificationFailed(key) }
        }
        if let artworkData, verified.artworkData != artworkData {
            throw MetadataError.verificationFailed("artwork")
        }
        guard try FileFingerprint(url: original) == attributes else { throw MetadataError.changedDuringEdit }
        _ = try FileManager.default.replaceItemAt(original, withItemAt: temporary)
        return try read(url: original)
    }

    public static func writeCUETrack(
        cueURL: URL, trackNumber: Int, title: String? = nil, artist: String? = nil,
        album: String? = nil, albumArtist: String? = nil, year: Int? = nil, genre: String? = nil,
        yearText: String? = nil, fallbackTrackArtists: [Int: String] = [:]
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let fingerprint = try FileFingerprint(url: cueURL)
        let originalData = try Data(contentsOf: cueURL)
        let (text, encoding) = try decodeCUE(originalData)
        let updated = try updatedCUEText(
            text, trackNumber: trackNumber, title: title, artist: artist,
            album: album, albumArtist: albumArtist, year: year, genre: genre, yearText: yearText,
            fallbackTrackArtists: fallbackTrackArtists
        )
        guard let data = updated.data(using: encoding) else {
            throw MetadataError.unsupported("The new metadata cannot be represented in this CUE sheet's text encoding.")
        }
        guard try FileFingerprint(url: cueURL) == fingerprint else { throw MetadataError.changedDuringEdit }
        try data.write(to: cueURL, options: .atomic)
    }

    /// Updates a textual CUE tag while retaining the audio file's other metadata.
    @discardableResult
    public static func writeEmbeddedCUETrack(
        audioURL: URL, trackNumber: Int, title: String? = nil, artist: String? = nil,
        album: String? = nil, albumArtist: String? = nil, year: Int? = nil, genre: String? = nil,
        yearText: String? = nil, fallbackTrackArtists: [Int: String] = [:]
    ) throws -> AudioFileMetadata {
        lock.lock()
        defer { lock.unlock() }
        let fingerprint = try FileFingerprint(url: audioURL)
        let existing = try properties(url: audioURL)
        guard let text = existing["CUESHEET"]?.first else {
            throw MetadataError.unsupported("This file has no textual embedded CUE sheet. Use an external CUE sheet to edit individual track metadata.")
        }
        let updated = try updatedCUEText(text, trackNumber: trackNumber, title: title,
                                         artist: artist, album: album, albumArtist: albumArtist,
                                         year: year, genre: genre, yearText: yearText,
                                         fallbackTrackArtists: fallbackTrackArtists)
        guard try FileFingerprint(url: audioURL) == fingerprint else { throw MetadataError.changedDuringEdit }
        return try write(properties: ["CUESHEET": updated], to: audioURL)
    }

    public static func updatedCUEText(
        _ text: String, trackNumber: Int, title: String? = nil, artist: String? = nil,
        album: String? = nil, albumArtist: String? = nil, year: Int? = nil, genre: String? = nil,
        yearText: String? = nil, fallbackTrackArtists: [Int: String] = [:]
    ) throws -> String {
        for value in [title, artist, album, albumArtist, genre].compactMap({ $0 }) + Array(fallbackTrackArtists.values) {
            if value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) {
                throw MetadataError.invalidCUEValue
            }
        }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let originalSheet = try CUEParser.parse(text)
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        let trackPattern = try NSRegularExpression(pattern: #"^\s*TRACK\s+(\d+)\s+AUDIO\s*$"#, options: .caseInsensitive)
        func trackNumberAt(_ line: String) -> Int? {
            guard let match = trackPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { return nil }
            return Int(line[range])
        }
        guard lines.contains(where: { trackNumberAt($0) == trackNumber }) else {
            throw MetadataError.cueTrackNotFound(trackNumber)
        }
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func apply(_ key: String, _ value: String?, global: Bool, quote: Bool = true, toTrack: Int? = nil) throws {
            guard let value else { return }
            let targetTrack = toTrack ?? trackNumber
            let tracks = lines.indices.filter { trackNumberAt(lines[$0]) != nil }
            let lower: Int
            let upper: Int
            let insertion: Int
            if global {
                lower = 0
                upper = tracks.first ?? lines.count
                insertion = lines.indices.first(where: { lines[$0].trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("FILE ") }) ?? upper
            } else {
                guard let start = tracks.first(where: { trackNumberAt(lines[$0]) == targetTrack }) else {
                    throw MetadataError.cueTrackNotFound(targetTrack)
                }
                lower = start + 1
                let nextTrack = tracks.first(where: { $0 > start }) ?? lines.count
                upper = (lower..<nextTrack).first(where: { lines[$0].trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("FILE ") }) ?? nextTrack
                insertion = lower
            }
            let pattern = try NSRegularExpression(pattern: "^\\s*" + NSRegularExpression.escapedPattern(for: key).replacingOccurrences(of: " ", with: "\\s+") + "(?:\\s+|$)", options: .caseInsensitive)
            let matches = (lower..<upper).filter { index in
                pattern.firstMatch(in: lines[index], range: NSRange(lines[index].startIndex..., in: lines[index])) != nil
            }
            let indent = matches.first.map { String(lines[$0].prefix(while: { $0 == " " || $0 == "\t" })) } ?? (global ? "" : "    ")
            let replacement = indent + key + " " + (quote ? quoted(value) : value)
            if let first = matches.first {
                for index in matches.reversed() {
                    if index == first && !value.isEmpty { lines[index] = replacement }
                    else { lines.remove(at: index) }
                }
            } else if !value.isEmpty { lines.insert(replacement, at: insertion) }
        }
        try apply("TITLE", album, global: true)
        try apply("PERFORMER", albumArtist, global: true)
        if let albumArtist, originalSheet.performer != albumArtist {
            // CUE's album performer is also the fallback track performer. Preserve
            // unchanged track artists when only the album-artist field is edited.
            for track in originalSheet.tracks where track.performer == nil {
                if let oldArtist = originalSheet.performer ?? fallbackTrackArtists[track.number] {
                    try apply("PERFORMER", oldArtist, global: false, toTrack: track.number)
                }
            }
        }
        try apply("REM DATE", yearText ?? year.map(String.init), global: true, quote: false)
        try apply("REM GENRE", genre, global: true)
        try apply("TITLE", title, global: false)
        try apply("PERFORMER", artist, global: false)
        let updated = lines.joined(separator: newline)
        _ = try CUEParser.parse(updated)
        return updated
    }

    private static func readDocument(url: URL) throws -> MCTagDocument {
        let document = MCReadTags(url)
        if let message = document.errorMessage { throw MetadataError.unsupported(message) }
        return document
    }

    private static func decodeCUE(_ data: Data) throws -> (String, String.Encoding) {
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        if (data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])),
           let text = String(data: data, encoding: .utf16) { return (text, .utf16) }
        if let text = String(data: data, encoding: .windowsCP1252) { return (text, .windowsCP1252) }
        throw MetadataError.unsupported("The CUE sheet's text encoding could not be read.")
    }
}

private struct FileFingerprint: Equatable {
    let size: UInt64
    let modified: Date
    let inode: UInt64

    init(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        modified = attributes[.modificationDate] as? Date ?? .distantPast
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

private enum FLACEmbeddedCUE {
    static func read(url: URL, sampleRate: Int?, properties: [String: [String]]) throws -> [AudioCuePoint]? {
        guard let sampleRate, sampleRate > 0 else { return nil }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try file.read(upToCount: 4) == Data("fLaC".utf8) else { return nil }
        var blockCount = 0
        while blockCount < 256 {
            blockCount += 1
            guard let header = try file.read(upToCount: 4), header.count == 4 else { return nil }
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            let type = header[0] & 0x7F
            if type == 5 {
                guard let payload = try file.read(upToCount: length), payload.count == length else { return nil }
                return parse(payload, sampleRate: sampleRate, properties: properties)
            }
            if header[0] & 0x80 != 0 { return nil }
            try file.seek(toOffset: file.offset() + UInt64(length))
        }
        return nil
    }

    private static func parse(_ data: Data, sampleRate: Int, properties: [String: [String]]) -> [AudioCuePoint]? {
        guard data.count >= 396 else { return nil }
        func uint64(at offset: Int) -> UInt64? {
            guard offset >= 0, offset + 8 <= data.count else { return nil }
            return (offset..<(offset + 8)).reduce(UInt64(0)) { $0 << 8 | UInt64(data[$1]) }
        }
        var offset = 396
        var starts: [(number: Int, sample: Int64)] = []
        var leadOut: Int64?
        for _ in 0..<Int(data[395]) {
            guard offset + 36 <= data.count, let trackOffset = uint64(at: offset), trackOffset <= UInt64(Int64.max) else { return nil }
            let number = Int(data[offset + 8])
            let count = Int(data[offset + 35])
            let isAudio = data[offset + 21] & 0x80 == 0
            offset += 36
            var indexOne: UInt64?
            var firstIndex: UInt64?
            for _ in 0..<count {
                guard offset + 12 <= data.count, let indexOffset = uint64(at: offset) else { return nil }
                let index = data[offset + 8]
                if firstIndex == nil { firstIndex = indexOffset }
                if index == 1 { indexOne = indexOffset }
                offset += 12
            }
            if count == 0 || number == 170 || number == 255 {
                leadOut = Int64(trackOffset)
                continue
            }
            guard isAudio, number > 0 else { continue }
            let (sample, overflow) = trackOffset.addingReportingOverflow(indexOne ?? firstIndex ?? 0)
            guard !overflow, sample <= UInt64(Int64.max) else { return nil }
            starts.append((number, Int64(sample)))
        }
        guard !starts.isEmpty else { return nil }
        let ordered = starts.sorted { $0.sample < $1.sample }
        return ordered.enumerated().map { index, entry in
            let end = index + 1 < ordered.count ? ordered[index + 1].sample : leadOut
            let title = properties[String(format: "MACAROK_CUE_TRACK_%02d_TITLE", entry.number)]?.first
            let artist = properties[String(format: "MACAROK_CUE_TRACK_%02d_ARTIST", entry.number)]?.first
            return AudioCuePoint(number: entry.number, startSample: entry.sample,
                                 endSample: end, sampleRate: sampleRate, title: title, artist: artist)
        }
    }
}
