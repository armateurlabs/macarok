import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct PodcastEpisode: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var description: String
    public var audioURL: URL
    public var publicationDate: Date?
    public var duration: Double
    public var artworkURL: URL?
    public var episodeNumber: Int?
    public var seasonNumber: Int?
    public var link: URL?
    /// Podcasting 2.0 JSON chapters, fetched only when the episode is used.
    public var chaptersURL: URL?
    /// Podlove Simple Chapters written in the feed.
    public var chapters: [PodcastChapter]

    public init(id: String, title: String, description: String = "", audioURL: URL,
                publicationDate: Date? = nil, duration: Double = 0, artworkURL: URL? = nil,
                episodeNumber: Int? = nil, seasonNumber: Int? = nil, link: URL? = nil,
                chaptersURL: URL? = nil, chapters: [PodcastChapter] = []) {
        self.id = id; self.title = title; self.description = description; self.audioURL = audioURL
        self.publicationDate = publicationDate; self.duration = duration; self.artworkURL = artworkURL
        self.episodeNumber = episodeNumber; self.seasonNumber = seasonNumber; self.link = link
        self.chaptersURL = chaptersURL; self.chapters = chapters
    }

    /// The library identity of this episode in a given source.
    public static func trackID(sourceID: String, episodeID: String) -> String { StableID.make(sourceID, "podcast", episodeID) }

    public func asTrackRecord(sourceID: String, feed: PodcastFeed, artworkPath: String? = nil) -> TrackRecord {
        TrackRecord(id: Self.trackID(sourceID: sourceID, episodeID: id), sourceID: sourceID,
                    albumID: StableID.make(sourceID, "podcast-feed", feed.url.absoluteString),
                    title: title, artist: feed.author.isEmpty ? feed.title : feed.author,
                    albumArtist: feed.author.isEmpty ? feed.title : feed.author, album: feed.title,
                    year: publicationDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) },
                    genre: "Podcast", trackNumber: episodeNumber, discNumber: seasonNumber,
                    duration: duration, fileURL: audioURL.absoluteString, remoteID: id,
                    format: audioURL.pathExtension.isEmpty ? "MP3" : audioURL.pathExtension.uppercased(),
                    artworkPath: artworkPath, addedAt: publicationDate ?? Date())
    }
}

public struct PodcastFeed: Sendable, Equatable {
    public var url: URL
    public var title: String
    public var author: String
    public var description: String
    public var artworkURL: URL?
    public var episodes: [PodcastEpisode]
    /// The show's website.
    public var link: URL?
    /// `itunes:type` serial shows are meant to be heard oldest first.
    public var isSerial: Bool

    public init(url: URL, title: String, author: String = "", description: String = "",
                artworkURL: URL? = nil, episodes: [PodcastEpisode] = [], link: URL? = nil, isSerial: Bool = false) {
        self.url = url; self.title = title; self.author = author; self.description = description
        self.artworkURL = artworkURL; self.episodes = episodes; self.link = link; self.isSerial = isSerial
    }
}

/// HTTP cache validators from the last successful feed response.
public struct PodcastFeedValidators: Sendable, Equatable {
    public var etag: String?
    public var lastModified: String?
    public init(etag: String? = nil, lastModified: String? = nil) { self.etag = etag; self.lastModified = lastModified }
    public var isEmpty: Bool { etag == nil && lastModified == nil }
}

public enum PodcastFetchResult: Sendable, Equatable {
    case notModified
    case feed(PodcastFeed, PodcastFeedValidators)
}

public enum PodcastError: LocalizedError, Sendable {
    case invalidFeed
    case parsing(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFeed: return "This URL does not contain an RSS or Atom podcast feed."
        case .parsing(let reason): return "The podcast feed could not be read: \(reason)"
        }
    }
}

public struct PodcastClient: Sendable {
    public let transport: SourceTransport
    public init(transport: SourceTransport) { self.transport = transport }

    public func fetchFeed(url: URL) async throws -> PodcastFeed {
        guard case let .feed(feed, _) = try await fetchFeed(url: url, validators: PodcastFeedValidators()) else { throw PodcastError.invalidFeed }
        return feed
    }

    /// Conditional GET: an unchanged feed answers 304 and is neither downloaded nor parsed again.
    public func fetchFeed(url: URL, validators: PodcastFeedValidators) async throws -> PodcastFetchResult {
        var request = URLRequest(url: url)
        request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")
        if let etag = validators.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified = validators.lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch SourceNetworkError.httpStatus(304) where !validators.isEmpty { return .notModified }
        let received = PodcastFeedValidators(etag: response.value(forHTTPHeaderField: "ETag"),
                                             lastModified: response.value(forHTTPHeaderField: "Last-Modified"))
        return .feed(try Self.parse(data: data, sourceURL: response.url ?? url), received)
    }

    public static func parse(data: Data, sourceURL: URL) throws -> PodcastFeed {
        let delegate = FeedParser(sourceURL: sourceURL)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw PodcastError.parsing(parser.parserError?.localizedDescription ?? "Invalid XML")
        }
        guard delegate.isFeed else { throw PodcastError.invalidFeed }
        return delegate.feed
    }

    /// Readable text from feed HTML: paragraphs, line breaks, and list items survive as line structure.
    public static func plainText(fromHTML value: String) -> String {
        var text = value.replacingOccurrences(of: "\r\n?", with: "\n", options: .regularExpression)
        if text.range(of: "<[a-zA-Z/!]", options: .regularExpression) != nil {
            // Source line breaks inside HTML are layout, not content.
            text = text.replacingOccurrences(of: "\\s*\n\\s*", with: " ", options: .regularExpression)
            for (pattern, replacement) in [("<br\\s*/?>", "\n"), ("<li[^>]*>", "\n• "),
                                           ("</(p|div|h[1-6]|ul|ol|blockquote|tr)>", "\n\n"), ("<(p|div|h[1-6])[^>]*>", "\n\n"),
                                           ("<!--.*?-->", ""), ("<[^>]+>", "")] {
                text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
            }
        }
        text = decodeEntities(text).removingInvisibleControls
        let lines = text.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "[ \\t\u{00A0}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        let named = ["nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'",
                     "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "hellip": "…", "mdash": "—", "ndash": "–",
                     "laquo": "«", "raquo": "»", "euro": "€", "copy": "©", "reg": "®", "trade": "™", "bull": "•",
                     "middot": "·", "deg": "°", "szlig": "ß", "aelig": "æ", "AElig": "Æ", "oelig": "œ", "OElig": "Œ"]
        let regex = try! NSRegularExpression(pattern: "&(#x?[0-9a-fA-F]+|[a-zA-Z]+|#39);")
        var result = ""
        var last = value.startIndex
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let range = Range(match.range, in: value), let nameRange = Range(match.range(at: 1), in: value) else { continue }
            let name = String(value[nameRange])
            var replacement = named[name] ?? named[name.lowercased()] ?? accented(name)
            if replacement == nil, name.hasPrefix("#") {
                let digits = name.dropFirst()
                let code = digits.lowercased().hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                replacement = code.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            }
            result += value[last..<range.lowerBound] + (replacement ?? String(value[range]))
            last = range.upperBound
        }
        return result + value[last...]
    }

    /// Latin letters with a diacritic, such as `eacute` or `Ccedil`, composed from their base letter.
    private static func accented(_ name: String) -> String? {
        let marks = ["acute": "\u{301}", "grave": "\u{300}", "circ": "\u{302}", "uml": "\u{308}",
                     "tilde": "\u{303}", "cedil": "\u{327}", "ring": "\u{30A}"]
        guard let letter = name.first, letter.isLetter, letter.isASCII, let mark = marks[String(name.dropFirst())] else { return nil }
        return (String(letter) + mark).precomposedStringWithCanonicalMapping
    }

    public static func duration(from value: String) -> Double {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(trimmed), seconds.isFinite { return max(0, seconds) }
        let components = trimmed.split(separator: ":")
        guard (2...3).contains(components.count), components.allSatisfy({ Double($0) != nil }) else { return 0 }
        let seconds = components.reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
        return seconds.isFinite ? max(0, seconds) : 0
    }
}

private final class FeedParser: NSObject, XMLParserDelegate {
    private struct Element { var name: String; var text: String = "" }
    private struct EpisodeBuilder {
        var id = ""
        var title = ""
        var description = ""
        var audioURL: URL?
        var publicationDate: Date?
        var duration: Double = 0
        var artworkURL: URL?
        var number: Int?
        var season: Int?
        var link: URL?
        var chaptersURL: URL?
        var chapters: [PodcastChapter] = []
    }

    private var elements: [Element] = []
    private var episode: EpisodeBuilder?
    private var seenIDs = Set<String>()
    var isFeed = false
    var feed: PodcastFeed

    init(sourceURL: URL) {
        feed = PodcastFeed(url: sourceURL, title: sourceURL.host ?? "Podcast")
    }

    private func resolve(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value, relativeTo: feed.url)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = elementName.lowercased()
        elements.append(Element(name: name))
        if name == "rss" || name == "feed" { isFeed = true }
        if name == "item" || name == "entry" { episode = EpisodeBuilder() }
        if name == "enclosure", let url = resolve(attributes["url"]) {
            let type = attributes["type"]?.lowercased() ?? ""
            if type.isEmpty || type.hasPrefix("audio/") || type == "application/ogg" { episode?.audioURL = url }
        }
        if name == "podcast:chapters", episode != nil, let url = resolve(attributes["url"]),
           attributes["type"].map({ $0.lowercased().contains("json") }) ?? true {
            episode?.chaptersURL = url
        }
        if name == "psc:chapter", episode != nil, let start = attributes["start"].flatMap(PodcastChapters.time) {
            episode?.chapters.append(PodcastChapter(start: start, title: PodcastClient.plainText(fromHTML: attributes["title"] ?? ""),
                                                    url: resolve(attributes["href"])))
        }
        if name == "link", ["alternate", nil].contains(attributes["rel"]?.lowercased()), let url = resolve(attributes["href"]) {
            if episode != nil, episode?.link == nil { episode?.link = url }
            else if elements.dropLast().last?.name == "feed" { feed.link = feed.link ?? url }
        }
        if name == "link", attributes["rel"]?.lowercased() == "enclosure", let url = resolve(attributes["href"]) {
            let type = attributes["type"]?.lowercased() ?? ""
            if type.isEmpty || type.hasPrefix("audio/") || type == "application/ogg" { episode?.audioURL = url }
        }
        if name == "media:content", attributes["type"]?.hasPrefix("audio/") == true || attributes["medium"] == "audio" {
            episode?.audioURL = resolve(attributes["url"]) ?? episode?.audioURL
        }
        if ["itunes:image", "media:thumbnail"].contains(name) || (name == "media:content" && (attributes["type"]?.hasPrefix("image/") == true || attributes["medium"] == "image")) {
            let url = resolve(attributes["href"] ?? attributes["url"])
            if episode != nil { episode?.artworkURL = url ?? episode?.artworkURL }
            else { feed.artworkURL = url ?? feed.artworkURL }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !elements.isEmpty else { return }
        elements[elements.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let element = elements.popLast() else { return }
        let name = element.name
        let value = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "item" || name == "entry" {
            if let item = episode, let audioURL = item.audioURL {
                let id = item.id.isEmpty ? StableID.make(audioURL.absoluteString) : item.id
                if seenIDs.insert(id).inserted {
                    feed.episodes.append(PodcastEpisode(id: id, title: item.title.isEmpty ? audioURL.deletingPathExtension().lastPathComponent : item.title,
                        description: item.description, audioURL: audioURL, publicationDate: item.publicationDate,
                        duration: item.duration, artworkURL: item.artworkURL ?? feed.artworkURL,
                        episodeNumber: item.number, seasonNumber: item.season, link: item.link,
                        chaptersURL: item.chaptersURL, chapters: item.chapters))
                }
            }
            episode = nil
            return
        }
        if episode != nil {
            switch name {
            case "title": episode?.title = value
            case "guid", "id": episode?.id = value
            case "description", "summary", "content:encoded", "content":
                if value.count >= (episode?.description.count ?? 0) { episode?.description = plainText(value) }
            case "pubdate", "published", "updated": episode?.publicationDate = date(value) ?? episode?.publicationDate
            case "itunes:duration", "duration": episode?.duration = PodcastClient.duration(from: value)
            case "itunes:episode": episode?.number = Int(value)
            case "itunes:season": episode?.season = Int(value)
            case "link": if !value.isEmpty, episode?.link == nil { episode?.link = resolve(value) }
            default: break
            }
        } else {
            switch name {
            case "title": if elements.last?.name == "channel" || elements.last?.name == "feed" { feed.title = value }
            case "itunes:author", "managingeditor": if feed.author.isEmpty { feed.author = value }
            case "name": if elements.last?.name == "author" { feed.author = value }
            case "description", "subtitle": if feed.description.isEmpty { feed.description = plainText(value) }
            case "url": if elements.last?.name == "image" { feed.artworkURL = resolve(value) ?? feed.artworkURL }
            case "logo", "icon": feed.artworkURL = resolve(value) ?? feed.artworkURL
            case "link": if elements.last?.name == "channel", !value.isEmpty { feed.link = feed.link ?? resolve(value) }
            case "itunes:type": feed.isSerial = value.lowercased() == "serial"
            default: break
            }
        }
        if !elements.isEmpty { elements[elements.count - 1].text += value }
    }

    private func plainText(_ value: String) -> String { PodcastClient.plainText(fromHTML: value) }

    private func date(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for pattern in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
