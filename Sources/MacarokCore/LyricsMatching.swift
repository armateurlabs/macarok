import Foundation

/// Lenient comparisons for automatic lyrics lookup. Leniency only widens which metadata spellings are
/// recognized; a different performance (live, remix, acoustic, …) or duration is still rejected.
enum LyricsMatching {
    private static let placeholders: Set<String> = [
        "unknown", "unknown album", "unknown artist", "unknown track", "unknown title", "untitled", "no album", "various artists"
    ]
    /// Words that name a different recording rather than a reissue of the same one.
    private static let distinctEditions: Set<String> = [
        "live", "acoustic", "remix", "instrumental", "karaoke", "demo", "cover", "unplugged", "orchestral", "piano", "rehearsal"
    ]
    private static let versionWords = ["remaster", "version", "edit", "mix", "mono", "stereo", "single", "radio", "bonus",
                                       "deluxe", "explicit", "clean", "feat", "ft", "from", "live", "acoustic", "demo"]

    /// Case-, diacritic-, and punctuation-insensitive; "&" reads as "and".
    static func folded(_ value: String) -> String {
        let lowered = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var result = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) { result.unicodeScalars.append(scalar) }
            else if scalar == "&" { result += " and " }
            else if scalar == "'" || scalar == "’" { continue }
            else { result += " " }
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Placeholders such as "Unknown Album" or "[Unknown Album]" describe missing metadata.
    static func isPlaceholder(_ value: String) -> Bool {
        let value = folded(value)
        return value.isEmpty || placeholders.contains(value)
    }

    static func meaningful(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return isPlaceholder(trimmed) ? nil : trimmed
    }

    /// Removes track-number prefixes, bracketed annotations, featured artists, and version suffixes.
    static func simplifiedTitle(_ title: String) -> String {
        var value = title.replacingOccurrences(of: #"^\s*\d{1,3}\s*[-.)]\s+"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s*[\(\[\{][^\)\]\}]*[\)\]\}]"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)\s+(feat\.?|ft\.?|featuring)\s.*$"#, with: "", options: .regularExpression)
        if let dash = value.range(of: " - ") {
            let suffix = folded(String(value[dash.upperBound...]))
            if versionWords.contains(where: { word in suffix.split(separator: " ").contains { $0.hasPrefix(word) } }) {
                value = String(value[..<dash.lowerBound])
            }
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : trimmed
    }

    /// Individual credited artists, folded; the first is the primary artist.
    static func artistNames(_ artist: String) -> [String] {
        artist.replacingOccurrences(of: #"(?i)\s*(,|;|/|&|\+|\s(feat\.?|ft\.?|featuring|with|x|and|vs\.?)\s)\s*"#, with: "|",
                                    options: .regularExpression)
            .split(separator: "|").map { folded(String($0)) }.filter { !$0.isEmpty }
    }

    static func titleMatches(_ candidate: String, _ query: String, allowSimplified: Bool) -> Bool {
        guard editions(candidate) == editions(query) else { return false }
        if folded(candidate) == folded(query) { return true }
        return allowSimplified && folded(simplifiedTitle(candidate)) == folded(simplifiedTitle(query))
    }

    static func artistMatches(_ candidate: String, _ query: String) -> Bool {
        if folded(candidate) == folded(query) { return true }
        let candidates = artistNames(candidate), queries = artistNames(query)
        return candidates.first != nil && candidates.first == queries.first || !Set(candidates).isDisjoint(with: queries)
    }

    private static func editions(_ title: String) -> Set<String> {
        Set(folded(title).split(separator: " ").map(String.init).filter(distinctEditions.contains))
    }
}
