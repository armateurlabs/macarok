import Foundation

public struct PlaylistEntry: Sendable, Equatable {
    public var url: URL
    public var title: String?
    public var duration: Double?
    public var startTime: Double?
    public var endTime: Double?
    public var trackID: String?
    public var sourceID: String?

    public init(url: URL, title: String? = nil, duration: Double? = nil,
                startTime: Double? = nil, endTime: Double? = nil,
                trackID: String? = nil, sourceID: String? = nil) {
        self.url = url; self.title = title; self.duration = duration
        self.startTime = startTime; self.endTime = endTime
        self.trackID = trackID; self.sourceID = sourceID
    }

    public init(track: TrackRecord) {
        let fallback = URL(string: "macarok://source/\(track.sourceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? track.sourceID)/track/\(track.id)")!
        self.init(url: track.url ?? fallback, title: "\(track.artist) - \(track.title)", duration: track.duration,
                  startTime: track.startTime, endTime: track.endTime, trackID: track.id, sourceID: track.sourceID)
    }
}

public enum PlaylistFileFormat: String, Sendable { case m3u, pls }

public enum PlaylistIOError: LocalizedError {
    case unreadable
    case segmentsRequireM3U
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "The playlist text could not be decoded."
        case .segmentsRequireM3U: return "Use an M3U playlist to preserve CUE track boundaries. PLS cannot represent these segments."
        }
    }
}

public enum PlaylistIO {
    public static func read(url: URL) throws -> [PlaylistEntry] {
        try parse(data: Data(contentsOf: url), playlistURL: url)
    }

    public static func parse(data: Data, playlistURL: URL) throws -> [PlaylistEntry] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .isoLatin1) else {
            throw PlaylistIOError.unreadable
        }
        return parse(text: text, playlistURL: playlistURL)
    }

    public static func parse(text: String, playlistURL: URL) -> [PlaylistEntry] {
        let cleaned = text.replacingOccurrences(of: "\u{FEFF}", with: "")
        if playlistURL.pathExtension.lowercased() == "pls" || cleaned.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("[playlist]") {
            return parsePLS(cleaned, relativeTo: playlistURL)
        }
        return parseM3U(cleaned, relativeTo: playlistURL)
    }

    public static func write(entries: [PlaylistEntry], to url: URL, relativePaths: Bool = true) throws {
        let format: PlaylistFileFormat = url.pathExtension.lowercased() == "pls" ? .pls : .m3u
        let text = try serialize(entries: entries, format: format, relativeTo: relativePaths ? url : nil)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func serialize(entries: [PlaylistEntry], format: PlaylistFileFormat = .m3u, relativeTo playlistURL: URL? = nil) throws -> String {
        switch format {
        case .m3u:
            var lines = ["#EXTM3U"]
            for entry in entries {
                let duration = entry.duration.flatMap { $0.isFinite && $0 >= 0 ? String(Int($0)) : nil } ?? "-1"
                lines.append("#EXTINF:\(duration),\(singleLine(entry.title ?? entry.url.deletingPathExtension().lastPathComponent))")
                if let value = entry.startTime, value.isFinite, value >= 0 { lines.append("#EXTVLCOPT:start-time=\(value)") }
                if let value = entry.endTime, value.isFinite, value >= 0 { lines.append("#EXTVLCOPT:stop-time=\(value)") }
                if let value = entry.trackID { lines.append("#MACAROK-TRACK-ID:\(singleLine(value))") }
                if let value = entry.sourceID { lines.append("#MACAROK-SOURCE-ID:\(singleLine(value))") }
                lines.append(location(for: entry.url, relativeTo: playlistURL))
            }
            return lines.joined(separator: "\n") + "\n"
        case .pls:
            guard !entries.contains(where: { $0.startTime != nil || $0.endTime != nil }) else {
                throw PlaylistIOError.segmentsRequireM3U
            }
            var lines = ["[playlist]", "NumberOfEntries=\(entries.count)"]
            for (index, entry) in entries.enumerated() {
                let number = index + 1
                lines.append("File\(number)=\(location(for: entry.url, relativeTo: playlistURL))")
                lines.append("Title\(number)=\(singleLine(entry.title ?? entry.url.deletingPathExtension().lastPathComponent))")
                lines.append("Length\(number)=\(entry.duration.flatMap { $0.isFinite && $0 >= 0 ? String(Int($0)) : nil } ?? "-1")")
                if let value = entry.startTime, value.isFinite, value >= 0 { lines.append("StartTime\(number)=\(value)") }
                if let value = entry.endTime, value.isFinite, value >= 0 { lines.append("EndTime\(number)=\(value)") }
                if let value = entry.trackID { lines.append("TrackID\(number)=\(singleLine(value))") }
                if let value = entry.sourceID { lines.append("SourceID\(number)=\(singleLine(value))") }
            }
            lines.append("Version=2")
            return lines.joined(separator: "\n") + "\n"
        }
    }

    private static func parseM3U(_ text: String, relativeTo playlistURL: URL) -> [PlaylistEntry] {
        var result: [PlaylistEntry] = []
        var title: String?
        var duration: Double?
        var start: Double?
        var end: Double?
        var trackID: String?
        var sourceID: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTINF:") {
                let parts = line.dropFirst(8).split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                duration = parts.first.flatMap { validTime(String($0)) }
                title = parts.count == 2 ? String(parts[1]) : nil
            } else if line.hasPrefix("#EXTVLCOPT:start-time=") { start = validTime(String(line.dropFirst(22))) }
            else if line.hasPrefix("#EXTVLCOPT:stop-time=") { end = validTime(String(line.dropFirst(21))) }
            else if line.hasPrefix("#MACAROK-TRACK-ID:") { trackID = String(line.dropFirst(18)) }
            else if line.hasPrefix("#MACAROK-SOURCE-ID:") { sourceID = String(line.dropFirst(19)) }
            else if line.hasPrefix("#") { continue }
            else {
                if let url = resolve(line, relativeTo: playlistURL) {
                    result.append(.init(url: url, title: title, duration: duration, startTime: start, endTime: end, trackID: trackID, sourceID: sourceID))
                }
                title = nil; duration = nil; start = nil; end = nil; trackID = nil; sourceID = nil
            }
        }
        return result
    }

    private static func parsePLS(_ text: String, relativeTo playlistURL: URL) -> [PlaylistEntry] {
        var values: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return values.keys.compactMap { key -> Int? in key.hasPrefix("file") ? Int(key.dropFirst(4)) : nil }.sorted().compactMap { index in
            guard let location = values["file\(index)"], let url = resolve(location, relativeTo: playlistURL) else { return nil }
            return .init(url: url, title: values["title\(index)"], duration: values["length\(index)"].flatMap(validTime),
                         startTime: values["starttime\(index)"].flatMap(validTime), endTime: values["endtime\(index)"].flatMap(validTime),
                         trackID: values["trackid\(index)"], sourceID: values["sourceid\(index)"])
        }
    }

    private static func validTime(_ value: String) -> Double? {
        guard let time = Double(value), time.isFinite, time >= 0 else { return nil }
        return time
    }

    private static func resolve(_ value: String, relativeTo playlistURL: URL) -> URL? {
        if let url = URL(string: value), url.scheme != nil { return url }
        let directory = playlistURL.deletingLastPathComponent()
        if value.contains("%"), let url = URL(string: value, relativeTo: directory)?.absoluteURL { return url.standardizedFileURL }
        return URL(fileURLWithPath: value, relativeTo: directory).standardizedFileURL
    }

    private static func location(for url: URL, relativeTo playlistURL: URL?) -> String {
        guard url.isFileURL else { return url.absoluteString }
        guard let playlistURL else { return url.path }
        let file = url.standardizedFileURL.pathComponents
        let base = playlistURL.deletingLastPathComponent().standardizedFileURL.pathComponents
        let common = zip(file, base).prefix(while: { $0 == $1 }).count
        return (Array(repeating: "..", count: base.count - common) + file.dropFirst(common)).joined(separator: "/")
    }

    private static func singleLine(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
    }
}
