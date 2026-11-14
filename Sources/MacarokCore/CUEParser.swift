import Foundation

public struct CUETime: Codable, Sendable, Hashable, Comparable {
    /// CUE timestamps are integral CD frames, not fractional milliseconds.
    public var frames: Int64
    public var seconds: Double { Double(frames) / 75 }

    public init(frames: Int64) { self.frames = frames }

    public init(_ value: String) throws {
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3,
              let minutes = Int64(components[0]), let seconds = Int64(components[1]),
              let frames = Int64(components[2]), minutes >= 0,
              minutes <= (Int64.max - 4_499) / 4_500,
              (0..<60).contains(seconds), (0..<75).contains(frames) else {
            throw CUEParserError.invalidTimestamp(value)
        }
        self.frames = minutes * 4_500 + seconds * 75 + frames
    }

    public var timestamp: String {
        String(format: "%02lld:%02lld:%02lld", frames / 4_500, frames / 75 % 60, frames % 75)
    }

    public static func < (lhs: CUETime, rhs: CUETime) -> Bool { lhs.frames < rhs.frames }
}

public struct CUETrack: Sendable, Hashable {
    public var number: Int
    public var title: String?
    public var performer: String?
    public var fileName: String
    public var index00: CUETime?
    public var index01: CUETime
    public var pregap: CUETime?

    public init(number: Int, title: String? = nil, performer: String? = nil, fileName: String,
                index00: CUETime? = nil, index01: CUETime, pregap: CUETime? = nil) {
        self.number = number
        self.title = title
        self.performer = performer
        self.fileName = fileName
        self.index00 = index00
        self.index01 = index01
        self.pregap = pregap
    }
}

public struct CUESheet: Sendable {
    public var title: String?
    public var performer: String?
    public var year: Int?
    public var genre: String?
    public var tracks: [CUETrack]
    public var originalText: String

    public init(title: String? = nil, performer: String? = nil, year: Int? = nil,
                genre: String? = nil, tracks: [CUETrack] = [], originalText: String = "") {
        self.title = title
        self.performer = performer
        self.year = year
        self.genre = genre
        self.tracks = tracks
        self.originalText = originalText
    }

    public var fileNames: [String] {
        var seen = Set<String>()
        return tracks.map(\.fileName).filter { seen.insert($0).inserted }
    }
}

public enum CUEParserError: LocalizedError, Equatable {
    case invalidTimestamp(String)
    case missingFile(Int)
    case missingIndex(Int)
    case invalidTrack(Int)
    case invalidIndexOrder(Int)
    case duplicateTrack(Int)
    case noAudioTracks
    case unsupportedEncoding
    case fileTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidTimestamp(let value): "Invalid CUE timestamp: \(value)."
        case .missingFile(let number): "CUE track \(number) does not reference an audio file."
        case .missingIndex(let number): "CUE track \(number) has no INDEX 01 marker."
        case .invalidTrack(let number): "Invalid CUE track number: \(number)."
        case .invalidIndexOrder(let number): "CUE track \(number) has inconsistent index markers."
        case .duplicateTrack(let number): "CUE track number \(number) is duplicated."
        case .noAudioTracks: "The CUE sheet contains no audio tracks."
        case .unsupportedEncoding: "The CUE sheet uses an unsupported text encoding."
        case .fileTooLarge: "The CUE sheet is too large to read."
        }
    }
}

public enum CUEParser {
    private struct PendingTrack {
        var number: Int
        var fileName: String
        var title: String?
        var performer: String?
        var index00: CUETime?
        var index01: CUETime?
        var pregap: CUETime?
    }

    public static func read(url: URL) throws -> CUESheet {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2_097_152 else { throw CUEParserError.fileTooLarge }
        let data = try Data(contentsOf: url)
        let hasUTF16BOM = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])
        let encodings: [String.Encoding] = hasUTF16BOM ? [.utf16, .utf8, .windowsCP1252, .isoLatin1] : [.utf8, .windowsCP1252, .isoLatin1]
        for encoding in encodings {
            if let string = String(data: data, encoding: encoding) { return try parse(string) }
        }
        throw CUEParserError.unsupportedEncoding
    }

    public static func parse(_ text: String) throws -> CUESheet {
        var sheet = CUESheet(originalText: text)
        var fileName: String?
        var pending: PendingTrack?
        var trackNumbers = Set<Int>()

        func complete(_ track: PendingTrack?) throws -> CUETrack? {
            guard let track else { return nil }
            guard !track.fileName.isEmpty else { throw CUEParserError.missingFile(track.number) }
            guard let index01 = track.index01 else { throw CUEParserError.missingIndex(track.number) }
            if let index00 = track.index00, index00 > index01 { throw CUEParserError.invalidIndexOrder(track.number) }
            return CUETrack(number: track.number, title: track.title, performer: track.performer,
                            fileName: track.fileName, index00: track.index00, index01: index01, pregap: track.pregap)
        }

        for rawLine in text.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let tokens = tokenize(line)
            guard let command = tokens.first?.uppercased() else { continue }
            switch command {
            case "FILE":
                if let track = try complete(pending) { sheet.tracks.append(track) }
                pending = nil
                if tokens.count >= 2 { fileName = tokens[1] }
            case "TRACK":
                if let track = try complete(pending) { sheet.tracks.append(track) }
                pending = nil
                guard tokens.count >= 3, tokens[2].uppercased() == "AUDIO" else { continue }
                guard let number = Int(tokens[1]), number > 0, number < 100 else {
                    throw CUEParserError.invalidTrack(Int(tokens[safe: 1] ?? "") ?? 0)
                }
                guard trackNumbers.insert(number).inserted else { throw CUEParserError.duplicateTrack(number) }
                pending = PendingTrack(number: number, fileName: fileName ?? "")
            case "TITLE":
                guard tokens.count >= 2 else { continue }
                let value = tokens.dropFirst().joined(separator: " ")
                if pending != nil { pending?.title = value } else if sheet.tracks.isEmpty { sheet.title = value }
            case "PERFORMER":
                guard tokens.count >= 2 else { continue }
                let value = tokens.dropFirst().joined(separator: " ")
                if pending != nil { pending?.performer = value } else if sheet.tracks.isEmpty { sheet.performer = value }
            case "INDEX":
                guard pending != nil, tokens.count >= 3 else { continue }
                if tokens[1] == "00" { pending?.index00 = try CUETime(tokens[2]) }
                if tokens[1] == "01" { pending?.index01 = try CUETime(tokens[2]) }
            case "PREGAP":
                if pending != nil, tokens.count >= 2 { pending?.pregap = try CUETime(tokens[1]) }
            case "REM":
                guard tokens.count >= 3 else { continue }
                if tokens[1].uppercased() == "DATE", sheet.year == nil {
                    sheet.year = Int(tokens[2].prefix(4))
                }
                if tokens[1].uppercased() == "GENRE", sheet.genre == nil {
                    sheet.genre = tokens.dropFirst(2).joined(separator: " ")
                }
            default: break
            }
        }
        if let track = try complete(pending) { sheet.tracks.append(track) }
        guard !sheet.tracks.isEmpty else { throw CUEParserError.noAudioTracks }
        var previousByFile: [String: CUETime] = [:]
        for track in sheet.tracks {
            if let previous = previousByFile[track.fileName], track.index01 <= previous {
                throw CUEParserError.invalidIndexOrder(track.number)
            }
            previousByFile[track.fileName] = track.index01
        }
        return sheet
    }

    /// A backslash only escapes a quote or another backslash; Windows file paths remain intact.
    private static func tokenize(_ line: String) -> [String] {
        let characters = Array(line)
        var values: [String] = []
        var current = ""
        var quoted = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", quoted, index + 1 < characters.count,
               characters[index + 1] == "\"" || characters[index + 1] == "\\" {
                current.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { values.append(current); current = "" }
            } else {
                current.append(character)
            }
            index += 1
        }
        if !current.isEmpty { values.append(current) }
        return values
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
