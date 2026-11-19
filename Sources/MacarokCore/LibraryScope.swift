import Foundation

/// Browsing scope is independent from the source that owns a playable track.
public enum LibraryScope: Codable, Hashable, Sendable {
    case all
    case source(String)
    /// Every subscribed show and the directory's previewed episodes.
    case podcasts

    /// Podcasts depends on the source's kind; without a kind, only `.all` and `.source` can include an ID.
    public func includes(sourceID: String, kind: SourceKind? = nil) -> Bool {
        switch self {
        case .all: true
        case .source(let id): id == sourceID
        case .podcasts: kind?.isPodcast == true
        }
    }

    public func includes(_ source: SourceRecord) -> Bool { includes(sourceID: source.id, kind: source.kind) }

    public var sourceID: String? {
        if case .source(let id) = self { return id }
        return nil
    }
}

extension AlbumRecord {
    /// Albums remain distinct when different sources reuse an upstream album ID.
    public var presentationID: String { StableID.make(sourceID, "album", id) }
}
