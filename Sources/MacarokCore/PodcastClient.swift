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

    public init(id: String, title: String, description: String = "", audioURL: URL,
                publicationDate: Date? = nil, duration: Double = 0, artworkURL: URL? = nil,
                episodeNumber: Int? = nil, seasonNumber: Int? = nil) {
        self.id = id; self.title = title; self.description = description; self.audioURL = audioURL
        self.publicationDate = publicationDate; self.duration = duration; self.artworkURL = artworkURL
        self.episodeNumber = episodeNumber; self.seasonNumber = seasonNumber
    }

    public func asTrackRecord(sourceID: String, feed: PodcastFeed, artworkPath: String? = nil) -> TrackRecord {
        TrackRecord(id: StableID.make(sourceID, "podcast", id), sourceID: sourceID,
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

    public init(url: URL, title: String, author: String = "", description: String = "",
                artworkURL: URL? = nil, episodes: [PodcastEpisode] = []) {
        self.url = url; self.title = title; self.author = author; self.description = description
        self.artworkURL = artworkURL; self.episodes = episodes
    }
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
        var request = URLRequest(url: url)
        request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.data(for: request)
        return try Self.parse(data: data, sourceURL: response.url ?? url)
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
                        episodeNumber: item.number, seasonNumber: item.season))
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
            default: break
            }
        }
        if !elements.isEmpty { elements[elements.count - 1].text += value }
    }

    private func plainText(_ value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
