import Foundation
import MacarokCore

/// The browsable lists whose direction can be reversed. Home shares the artist list.
enum LibrarySortKey: String, Codable, CaseIterable, Sendable {
    case artists, albums, years, folders, tags, podcasts
}

extension LibraryView {
    var sortKey: LibrarySortKey {
        switch self {
        case .home, .artists: .artists
        case .albums: .albums
        case .years: .years
        case .folders: .folders
        case .tags: .tags
        case .podcasts: .podcasts
        }
    }
}

struct LibrarySortOrder: Codable, Equatable, Sendable {
    /// Years have always listed the newest first; every other list starts in ascending natural order.
    private(set) var descending: Set<LibrarySortKey> = [.years]

    init() {}

    /// Podcasts default to newest first, including preferences saved before the key existed,
    /// so their membership records a reversal of that default instead of a descending order.
    func isDescending(_ key: LibrarySortKey) -> Bool { key == .podcasts ? !descending.contains(key) : descending.contains(key) }

    mutating func toggle(_ key: LibrarySortKey) {
        if descending.contains(key) { descending.remove(key) } else { descending.insert(key) }
    }

    init(from decoder: Decoder) throws {
        // Unknown keys from a later version are ignored rather than discarding every preference.
        let container = try decoder.singleValueContainer()
        let values = (try? container.decode([String].self)) ?? []
        descending = Set(values.compactMap(LibrarySortKey.init(rawValue:)))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(descending.map(\.rawValue).sorted())
    }
}

/// Browsing lists in the selected direction. Canonical snapshot arrays stay ascending because
/// rankings, lookups, and incremental patches depend on their deterministic order.
struct LibraryPresentation: Sendable {
    let order: LibrarySortOrder
    let artists: [LibraryArtistGroup]
    let albums: [AlbumRecord]
    let yearGroups: [LibraryYearGroup]
    let genreGroups: [LibraryTrackGroup]
    let formatGroups: [LibraryTrackGroup]
    let folderNodes: [FolderNode]

    static let empty = LibraryPresentation(order: LibrarySortOrder(), artists: [], albums: [], yearGroups: [],
                                           genreGroups: [], formatGroups: [], folderNodes: [])

    /// Canonical inputs are strictly ordered, so reversing them is the exact opposite natural order.
    /// Years arrive newest first with Unknown Year last; Unknown stays last in both directions.
    init(order: LibrarySortOrder, artists: [LibraryArtistGroup], albums: [AlbumRecord], yearGroups: [LibraryYearGroup],
         genreGroups: [LibraryTrackGroup], formatGroups: [LibraryTrackGroup], folderNodes: [FolderNode]) {
        self.order = order
        self.artists = order.isDescending(.artists) ? artists.reversed() : artists
        self.albums = order.isDescending(.albums) ? albums.reversed() : albums
        if order.isDescending(.years) { self.yearGroups = yearGroups }
        else {
            let known = yearGroups.filter { $0.year != nil }
            self.yearGroups = known.reversed() + yearGroups.filter { $0.year == nil }
        }
        let tags = order.isDescending(.tags)
        self.genreGroups = tags ? genreGroups.reversed() : genreGroups
        self.formatGroups = tags ? formatGroups.reversed() : formatGroups
        // Roots remain in source order; every folder's children follow the selected direction.
        self.folderNodes = order.isDescending(.folders) ? folderNodes.map(Self.reversingChildren) : folderNodes
    }

    private static func reversingChildren(_ node: FolderNode) -> FolderNode {
        FolderNode(id: node.id, name: node.name, children: node.children.map { $0.reversed().map(reversingChildren) })
    }
}
