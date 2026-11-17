import Foundation

/// One chapter of a podcast episode.
public struct PodcastChapter: Codable, Sendable, Hashable {
    public var start: Double
    public var title: String
    public var url: URL?

    public init(start: Double, title: String, url: URL? = nil) {
        self.start = start; self.title = title; self.url = url
    }
}

public enum PodcastChapters {
    /// Sorted, deduplicated chapters inside the episode. Fewer than two is not a chapter list.
    /// A list that starts after 0 gets an untitled opening chapter so every moment has a chapter.
    public static func normalized(_ chapters: [PodcastChapter], duration: Double? = nil) -> [PodcastChapter] {
        var seen = Set<Double>()
        var result = chapters.filter { chapter in
            guard chapter.start.isFinite, chapter.start >= 0 else { return false }
            if let duration, duration > 0, chapter.start >= duration { return false }
            return true
        }.sorted { $0.start < $1.start }.filter { seen.insert(($0.start * 1000).rounded()).inserted }
            .map { PodcastChapter(start: $0.start, title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines), url: $0.url) }
        guard result.count >= 2 else { return [] }
        if result[0].start > 0 { result.insert(PodcastChapter(start: 0, title: ""), at: 0) }
        return result
    }

    /// Podcasting 2.0 JSON chapters. Chapters with `"toc": false` are not navigation points.
    public static func parseJSON(_ data: Data) throws -> [PodcastChapter] {
        struct Document: Decodable {
            struct Chapter: Decodable { var startTime: Double?; var title: String?; var url: String?; var toc: Bool? }
            var chapters: [Chapter]
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        return document.chapters.compactMap { chapter in
            guard chapter.toc != false, let start = chapter.startTime else { return nil }
            let url = chapter.url.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
            return PodcastChapter(start: start, title: chapter.title ?? "", url: url)
        }
    }

    /// Podlove normal play time: `HH:MM:SS(.mmm)`, `MM:SS(.mmm)`, or seconds.
    public static func time(_ value: String) -> Double? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for (index, part) in parts.enumerated() {
            guard let number = Double(part), number >= 0, number.isFinite else { return nil }
            if index < parts.count - 1 && (number != number.rounded()) { return nil }
            seconds = seconds * 60 + number
        }
        return seconds
    }

    private static let leadingTime = try! NSRegularExpression(
        pattern: #"^[^\p{L}\p{N}]{0,6}?(?:\(|\[)?((?:\d{1,2}:)?\d{1,2}:\d{2})(?:\)|\])?\s*[-–—:|·.]*\s*(.*)$"#)

    /// Chapter lists written in episode notes: at least three lines that start with a time, in
    /// increasing order, the first within five minutes and all inside the episode. Times inside
    /// sentences are ignored, so prose such as "rendez-vous à 14:30" is not a chapter.
    public static func fromNotes(_ notes: String, duration: Double) -> [PodcastChapter] {
        var chapters: [PodcastChapter] = []
        for line in notes.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = leadingTime.firstMatch(in: line, range: range),
                  let timeRange = Range(match.range(at: 1), in: line), let start = time(String(line[timeRange])) else { continue }
            let title = Range(match.range(at: 2), in: line).map { String(line[$0]) } ?? ""
            chapters.append(PodcastChapter(start: start, title: title))
        }
        guard chapters.count >= 3, let first = chapters.first, first.start <= 300,
              zip(chapters, chapters.dropFirst()).allSatisfy({ $0.start < $1.start }),
              duration <= 0 || chapters.last!.start < duration else { return [] }
        return normalized(chapters, duration: duration > 0 ? duration : nil)
    }
}
