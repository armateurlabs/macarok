import Foundation
import MacarokCore

struct LibraryYearGroup: Identifiable, Sendable {
    let id: Int
    let year: Int?
    let title: String
    let albums: [AlbumRecord]
}

struct LibraryTrackGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let tracks: [TrackRecord]
}

struct LibraryArtistGroup: Identifiable, Sendable {
    let id: String
    let name: String
    let albums: [AlbumRecord]
    let trackCount: Int
    let playCount: Int
    let sourceIDs: Set<String>
    let artworkPath: String?

    static func normalizedName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    init(name: String, albums: [AlbumRecord]) {
        self.id = StableID.make("artist", Self.normalizedName(name))
        self.name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.albums = albums.sorted {
            if ($0.year ?? 0) != ($1.year ?? 0) { return ($0.year ?? 0) < ($1.year ?? 0) }
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.presentationID < $1.presentationID : order == .orderedAscending
        }
        trackCount = albums.reduce(0) { $0 + $1.tracks.count }
        playCount = albums.reduce(0) { $0 + $1.playCount }
        sourceIDs = Set(albums.map(\.sourceID))
        artworkPath = self.albums.lazy.compactMap(\.artworkPath).first
    }
}

private struct LibraryAlbumKey: Hashable {
    let sourceID: String
    let albumID: String
}

/// Immutable presentation data. Build on a worker and publish the completed value on the main actor.
struct LibrarySnapshot: Sendable {
    let scope: LibraryScope?
    var sourceID: String? { scope?.sourceID }
    let tracks: [TrackRecord]
    let tracksByID: [String: TrackRecord]
    let albums: [AlbumRecord]
    let albumsByID: [String: AlbumRecord]
    let artists: [LibraryArtistGroup]
    let artistsByName: [String: LibraryArtistGroup]
    let yearGroups: [LibraryYearGroup]
    let genreGroups: [LibraryTrackGroup]
    let formatGroups: [LibraryTrackGroup]
    let recentlyAdded: [AlbumRecord]
    let mostPlayedAlbums: [AlbumRecord]
    let recentlyPlayed: [TrackRecord]
    let mostPlayedTracks: [TrackRecord]
    let mostPlayedArtists: [LibraryArtistGroup]
    let folderNodes: [FolderNode]
    let tracksByFolder: [String: [TrackRecord]]
    let folderTitles: [String: String]

    static let empty = LibrarySnapshot(scope: nil, tracks: [], tracksByID: [:], albums: [], albumsByID: [:],
                                       artists: [], artistsByName: [:], yearGroups: [], genreGroups: [], formatGroups: [],
                                       recentlyAdded: [], mostPlayedAlbums: [], recentlyPlayed: [], mostPlayedTracks: [],
                                       mostPlayedArtists: [], folderNodes: [], tracksByFolder: [:], folderTitles: [:])

    static func build(sourceID: String, tracks: [TrackRecord], sources: [SourceRecord]) throws -> LibrarySnapshot {
        try build(scope: .source(sourceID), tracks: tracks, sources: sources)
    }

    static func build(scope: LibraryScope, tracks input: [TrackRecord], sources: [SourceRecord]) throws -> LibrarySnapshot {
        try Task.checkCancellation()
        let visibleSources = sources.filter { scope.includes(sourceID: $0.id) }
        let registeredIDs = Set(visibleSources.map(\.id))
        var seen: Set<String> = []
        var tracks: [TrackRecord] = []
        tracks.reserveCapacity(input.count)
        for (index, track) in input.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard scope.includes(sourceID: track.sourceID), registeredIDs.contains(track.sourceID),
                  track.isAvailable, seen.insert(track.id).inserted else { continue }
            tracks.append(track)
        }
        tracks = try tracks.sorted { try Task.checkCancellation(); return TrackRecord.libraryOrder($0, $1) }

        var tracksByID: [String: TrackRecord] = [:]
        var albumTracks: [LibraryAlbumKey: [TrackRecord]] = [:]
        var genres: [String: [TrackRecord]] = [:]
        var formats: [String: [TrackRecord]] = [:]
        var tracksByFolder: [String: [TrackRecord]] = ["": tracks]
        var folderNames: [String: String] = [:]
        var childFolders: [String: [String]] = [:]
        let resolver = LibraryFolderPathResolver(sources: visibleSources)
        let allSources = scope == .all
        let sourceRootIDs = Dictionary(uniqueKeysWithValues: visibleSources.map { ($0.id, "source:" + StableID.make($0.id)) })
        func rootKey(_ sourceID: String) -> String { allSources ? sourceRootIDs[sourceID, default: ""] : "" }
        for source in visibleSources {
            let root = rootKey(source.id)
            folderNames[root] = source.name
            if allSources { tracksByFolder[root] = [] }
        }
        tracksByID.reserveCapacity(tracks.count)
        for (index, track) in tracks.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            tracksByID[track.id] = track
            albumTracks[LibraryAlbumKey(sourceID: track.sourceID, albumID: track.albumID), default: []].append(track)
            genres[track.genre.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown", default: []].append(track)
            formats[track.format.isEmpty ? "Unknown Format" : track.format, default: []].append(track)
            var parent = rootKey(track.sourceID)
            if allSources { tracksByFolder[parent, default: []].append(track) }
            for component in resolver.folderPath(track).split(separator: "/") {
                let name = String(component)
                let id = parent.isEmpty ? name : parent + "/" + name
                if folderNames[id] == nil {
                    folderNames[id] = name
                    childFolders[parent, default: []].append(id)
                }
                tracksByFolder[id, default: []].append(track)
                parent = id
            }
        }

        var albums: [AlbumRecord] = []
        albums.reserveCapacity(albumTracks.count)
        for values in albumTracks.values { try Task.checkCancellation(); albums.append(AlbumRecord(orderedTracks: values)) }
        albums = try albums.sorted { try Task.checkCancellation(); return albumOrder($0, $1) }
        var albumsByID: [String: AlbumRecord] = [:]
        var artistAlbums: [String: [AlbumRecord]] = [:]
        var artistNames: [String: Set<String>] = [:]
        var albumsByYear: [Int: [AlbumRecord]] = [:]
        for album in albums {
            try Task.checkCancellation()
            albumsByID[album.presentationID] = album
            let key = LibraryArtistGroup.normalizedName(album.artist)
            artistAlbums[key, default: []].append(album)
            artistNames[key, default: []].insert(album.artist.split(whereSeparator: \.isWhitespace).joined(separator: " "))
            albumsByYear[album.year ?? 0, default: []].append(album)
        }
        var artists: [LibraryArtistGroup] = []
        for (key, values) in artistAlbums {
            try Task.checkCancellation()
            let name = artistNames[key]?.sorted().first ?? key
            artists.append(LibraryArtistGroup(name: name, albums: values))
        }
        artists = try artists.sorted { try Task.checkCancellation(); return stringOrder($0.name, $1.name) }
        let artistsByName = Dictionary(uniqueKeysWithValues: artists.map { (LibraryArtistGroup.normalizedName($0.name), $0) })
        let years = albumsByYear.keys.sorted { lhs, rhs in
            if lhs == 0 { return false }
            if rhs == 0 { return true }
            return lhs > rhs
        }
        let yearGroups = years.map { year in
            LibraryYearGroup(id: year, year: year == 0 ? nil : year,
                             title: year == 0 ? "Unknown Year" : String(year), albums: albumsByYear[year] ?? [])
        }
        func folder(_ id: String, name: String) throws -> FolderNode {
            try Task.checkCancellation()
            let children = try (childFolders[id] ?? []).sorted {
                stringOrder(folderNames[$0, default: ""], folderNames[$1, default: ""])
            }.map { try folder($0, name: folderNames[$0, default: ""]) }
            return FolderNode(id: id, name: name, children: children.isEmpty ? nil : children)
        }
        let folderNodes: [FolderNode]
        if allSources {
            folderNodes = try visibleSources.map { try folder(rootKey($0.id), name: $0.name) }
        } else {
            folderNodes = [try folder("", name: visibleSources.first?.name ?? "Music")]
        }
        let recentlyAdded = Array(albums.sorted { $0.addedAt == $1.addedAt ? albumOrder($0, $1) : $0.addedAt > $1.addedAt }.prefix(8))
        let mostPlayedAlbums = Array(albums.filter { $0.playCount > 0 }.sorted {
            $0.playCount == $1.playCount ? albumOrder($0, $1) : $0.playCount > $1.playCount
        }.prefix(8))
        let recentlyPlayed = Array(tracks.filter { $0.lastPlayedAt != nil }.sorted {
            let left = $0.lastPlayedAt ?? .distantPast, right = $1.lastPlayedAt ?? .distantPast
            return left == right ? TrackRecord.libraryOrder($0, $1) : left > right
        }.prefix(8))
        let mostPlayedTracks = Array(tracks.filter { $0.playCount > 0 }.sorted {
            $0.playCount == $1.playCount ? TrackRecord.libraryOrder($0, $1) : $0.playCount > $1.playCount
        }.prefix(8))
        let mostPlayedArtists = Array(artists.filter { $0.playCount > 0 }.sorted {
            $0.playCount == $1.playCount ? stringOrder($0.name, $1.name) : $0.playCount > $1.playCount
        }.prefix(8))
        return LibrarySnapshot(scope: scope, tracks: tracks, tracksByID: tracksByID, albums: albums, albumsByID: albumsByID,
                               artists: artists, artistsByName: artistsByName, yearGroups: yearGroups,
                               genreGroups: trackGroups(genres), formatGroups: trackGroups(formats), recentlyAdded: recentlyAdded,
                               mostPlayedAlbums: mostPlayedAlbums, recentlyPlayed: recentlyPlayed, mostPlayedTracks: mostPlayedTracks,
                               mostPlayedArtists: mostPlayedArtists, folderNodes: folderNodes, tracksByFolder: tracksByFolder,
                               folderTitles: folderNames)
    }

    private static func trackGroups(_ groups: [String: [TrackRecord]]) -> [LibraryTrackGroup] {
        groups.keys.sorted(by: stringOrder).map { LibraryTrackGroup(id: $0, title: $0, tracks: groups[$0] ?? []) }
    }
    private static func albumOrder(_ lhs: AlbumRecord, _ rhs: AlbumRecord) -> Bool {
        let title = lhs.title.localizedStandardCompare(rhs.title)
        if title != .orderedSame { return title == .orderedAscending }
        let artist = lhs.artist.localizedStandardCompare(rhs.artist)
        if artist != .orderedSame { return artist == .orderedAscending }
        return lhs.id == rhs.id ? lhs.sourceID < rhs.sourceID : lhs.id < rhs.id
    }
    private static func stringOrder(_ lhs: String, _ rhs: String) -> Bool {
        let order = lhs.localizedStandardCompare(rhs)
        return order == .orderedSame ? lhs < rhs : order == .orderedAscending
    }
}
