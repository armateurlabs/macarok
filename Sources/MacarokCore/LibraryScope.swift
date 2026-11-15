import Foundation

/// Browsing scope is independent from the source that owns a playable track.
public enum LibraryScope: Codable, Hashable, Sendable {
    case all
    case source(String)

    public func includes(sourceID: String) -> Bool {
        switch self {
        case .all: true
        case .source(let id): id == sourceID
        }
    }

    public var sourceID: String? {
        if case .source(let id) = self { return id }
        return nil
    }
}

extension AlbumRecord {
    /// Albums remain distinct when different sources reuse an upstream album ID.
    public var presentationID: String { StableID.make(sourceID, "album", id) }
}
