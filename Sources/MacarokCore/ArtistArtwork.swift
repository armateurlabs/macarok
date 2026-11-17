import Foundation
import GRDB

/// One picture per artist name, shared by every album and source that credits the artist.
public struct ArtistArtworkRecord: Sendable, Equatable {
    public var key: String
    public var name: String
    /// Nil records a lookup that found nothing, so it is not repeated on every visit.
    public var path: String?
    public var origin: String?
    public var manual: Bool
    public var checkedAt: Date

    public init(key: String, name: String, path: String?, origin: String?, manual: Bool, checkedAt: Date) {
        self.key = key; self.name = name; self.path = path; self.origin = origin; self.manual = manual; self.checkedAt = checkedAt
    }
}

public enum ArtistArtworkKey {
    /// Case, accent and spacing differences between sources still share one picture.
    public static func make(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func isMeaningful(_ name: String) -> Bool {
        let key = make(name)
        return !key.isEmpty && !["unknown artist", "various artists", "various", "choose an artist"].contains(key)
    }
}

public enum ArtistArtworkStorage {
    public static func registerMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("artist-artwork-v1") { db in
            try db.execute(sql: """
                CREATE TABLE artistArtwork (
                    nameKey TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    path TEXT,
                    origin TEXT,
                    manual BOOLEAN NOT NULL DEFAULT 0,
                    checkedAt DOUBLE NOT NULL
                );
                """)
        }
    }
}

extension LibraryStore {
    public func artistArtwork(named name: String) throws -> ArtistArtworkRecord? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM artistArtwork WHERE nameKey = ?", arguments: [ArtistArtworkKey.make(name)])
                .map(Self.artistArtworkRecord)
        }
    }

    public func allArtistArtwork() throws -> [ArtistArtworkRecord] {
        try database.read { db in try Row.fetchAll(db, sql: "SELECT * FROM artistArtwork").map(Self.artistArtworkRecord) }
    }

    /// Automatic results never replace a picture the user chose.
    public func saveArtistArtwork(name: String, path: String?, origin: String?, manual: Bool, now: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO artistArtwork(nameKey, name, path, origin, manual, checkedAt) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(nameKey) DO UPDATE SET
                    name = excluded.name, path = excluded.path, origin = excluded.origin,
                    manual = excluded.manual, checkedAt = excluded.checkedAt
                WHERE artistArtwork.manual = 0 OR excluded.manual = 1
                """, arguments: [ArtistArtworkKey.make(name), name, path, origin, manual, now.timeIntervalSince1970])
        }
    }

    public func removeArtistArtwork(named name: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM artistArtwork WHERE nameKey = ?", arguments: [ArtistArtworkKey.make(name)])
        }
    }

    private static func artistArtworkRecord(_ row: Row) -> ArtistArtworkRecord {
        ArtistArtworkRecord(key: row["nameKey"], name: row["name"], path: row["path"], origin: row["origin"],
                            manual: row["manual"], checkedAt: Date(timeIntervalSince1970: row["checkedAt"]))
    }
}

/// A picture found online for an artist.
public struct ArtistImageCandidate: Sendable, Equatable, Identifiable {
    public var id: String { imageURL.absoluteString }
    public var title: String
    public var detail: String
    public var origin: String
    public var thumbnailURL: URL
    public var imageURL: URL

    public init(title: String, detail: String, origin: String, thumbnailURL: URL, imageURL: URL) {
        self.title = title; self.detail = detail; self.origin = origin; self.thumbnailURL = thumbnailURL; self.imageURL = imageURL
    }
}

/// Lead images of English Wikipedia articles, through the public MediaWiki API.
public struct WikipediaImageClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    static let userAgent = "Macarok/0.1 (macOS; https://github.com/armateurlabs/macarok)"

    public init(transport: Transport? = nil) {
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, response)
        }
    }

    /// Articles about the artist that have a lead image, best match first.
    public func artistImages(for artist: String, limit: Int = 8) async throws -> [ArtistImageCandidate] {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"), .init(name: "formatversion", value: "2"),
            .init(name: "generator", value: "search"), .init(name: "gsrsearch", value: "\(artist) music"),
            .init(name: "gsrlimit", value: String(limit)), .init(name: "gsrnamespace", value: "0"), .init(name: "redirects", value: "1"),
            .init(name: "prop", value: "pageimages|description"), .init(name: "piprop", value: "thumbnail|original"),
            // An 800-pixel rendition is plenty for a square picture and avoids multi-megabyte originals.
            .init(name: "pithumbsize", value: "800"), .init(name: "pilicense", value: "any"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let pages = ((body?["query"] as? [String: Any])?["pages"] as? [[String: Any]]) ?? []
        let target = ArtistArtworkKey.make(artist)
        return pages.sorted { ($0["index"] as? Int ?? .max) < ($1["index"] as? Int ?? .max) }.compactMap { page in
            guard let title = page["title"] as? String,
                  let thumbnail = (page["thumbnail"] as? [String: Any])?["source"] as? String, let thumbnailURL = URL(string: thumbnail),
                  let original = (page["original"] as? [String: Any])?["source"] as? String, let originalURL = URL(string: original),
                  !Self.isVectorOrLogo(originalURL) else { return nil }
            return ArtistImageCandidate(title: title, detail: page["description"] as? String ?? "Wikipedia", origin: "Wikipedia",
                                        thumbnailURL: thumbnailURL, imageURL: thumbnailURL)
        }.sorted { Self.matches($0.title, target) && !Self.matches($1.title, target) }
    }

    /// The first image whose article is named after the artist, e.g. "Name" or "Name (band)".
    public func bestArtistImage(for artist: String) async throws -> ArtistImageCandidate? {
        let target = ArtistArtworkKey.make(artist)
        return try await artistImages(for: artist).first { Self.matches($0.title, target) && !$0.detail.lowercased().contains("disambiguation") }
    }

    static func matches(_ title: String, _ target: String) -> Bool {
        let key = ArtistArtworkKey.make(title)
        return key == target || key.hasPrefix(target + " (")
    }

    private static func isVectorOrLogo(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".svg") || name.contains("logo")
    }
}

extension LastFMClient {
    /// Last.fm's placeholder star is returned for artists without a real picture; it is ignored.
    public static let placeholderImageHash = "2a96cbd8b46e442fc41c2b86b821562f"
}
