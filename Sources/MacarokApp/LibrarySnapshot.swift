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

/// Immutable presentation data. Build on a worker and publish the completed value on the main actor.
struct LibrarySnapshot: Sendable {
    let sourceID: String?
    let tracks: [TrackRecord]
    let tracksByID: [String: TrackRecord]
    let albums: [AlbumRecord]
    let albumsByID: [String: AlbumRecord]
    let artists: [ArtistSummary]
    let artistsByName: [String: ArtistSummary]
    let yearGroups: [LibraryYearGroup]
    let genreGroups: [LibraryTrackGroup]
    let formatGroups: [LibraryTrackGroup]
    let recentlyAdded: [AlbumRecord]
    let mostPlayedAlbums: [AlbumRecord]
    let recentlyPlayed: [TrackRecord]
    let mostPlayedTracks: [TrackRecord]
    let mostPlayedArtists: [ArtistSummary]
    let folderNodes: [FolderNode]
    let tracksByFolder: [String: [TrackRecord]]

    static let empty = LibrarySnapshot(sourceID: nil, tracks: [], tracksByID: [:], albums: [], albumsByID: [:],
                                       artists: [], artistsByName: [:], yearGroups: [], genreGroups: [], formatGroups: [],
                                       recentlyAdded: [], mostPlayedAlbums: [], recentlyPlayed: [], mostPlayedTracks: [],
                                       mostPlayedArtists: [], folderNodes: [], tracksByFolder: [:])

    static func build(sourceID: String, tracks input: [TrackRecord], sources: [SourceRecord]) throws -> LibrarySnapshot {
        try Task.checkCancellation()
        var seen: Set<String> = []
        var tracks: [TrackRecord] = []
        tracks.reserveCapacity(input.count)
        for (index, track) in input.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard track.sourceID == sourceID, track.isAvailable, seen.insert(track.id).inserted else { continue }
            tracks.append(track)
        }
        tracks = try tracks.sorted {
            try Task.checkCancellation()
            return TrackRecord.libraryOrder($0, $1)
        }

        var tracksByID: [String: TrackRecord] = [:]
        var albumTracks: [String: [TrackRecord]] = [:]
        var genres: [String: [TrackRecord]] = [:]
        var formats: [String: [TrackRecord]] = [:]
        var tracksByFolder: [String: [TrackRecord]] = ["": tracks]
        var folderNames: [String: String] = [:]
        var childFolders: [String: [String]] = [:]
        let source = sources.first { $0.id == sourceID }
        let resolver = LibraryFolderPathResolver(sources: source.map { [$0] } ?? [])
        tracksByID.reserveCapacity(tracks.count)
        for (index, track) in tracks.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            tracksByID[track.id] = track
            albumTracks[track.albumID, default: []].append(track)
            let genre = track.genre.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown"
            let format = track.format.isEmpty ? "Unknown Format" : track.format
            genres[genre, default: []].append(track)
            formats[format, default: []].append(track)
            var parent = ""
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

        // Global track order already puts each album's tracks in playback order.
        var albums: [AlbumRecord] = []
        albums.reserveCapacity(albumTracks.count)
        for values in albumTracks.values {
            try Task.checkCancellation()
            albums.append(AlbumRecord(orderedTracks: values))
        }
        albums = try albums.sorted {
            try Task.checkCancellation()
            return albumOrder($0, $1)
        }
        var albumsByID: [String: AlbumRecord] = [:]
        var artistAlbums: [String: [AlbumRecord]] = [:]
        var albumsByYear: [Int: [AlbumRecord]] = [:]
        for album in albums {
            try Task.checkCancellation()
            albumsByID[album.id] = album
            artistAlbums[album.artist, default: []].append(album)
            albumsByYear[album.year ?? 0, default: []].append(album)
        }
        var artists: [ArtistSummary] = []
        artists.reserveCapacity(artistAlbums.count)
        for (name, values) in artistAlbums {
            try Task.checkCancellation()
            artists.append(ArtistSummary(name: name, sourceID: sourceID, albums: values))
        }
        artists = try artists.sorted {
            try Task.checkCancellation()
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        let artistsByName = Dictionary(uniqueKeysWithValues: artists.map { ($0.name, $0) })
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
        let folderNodes = [try folder("", name: source?.name ?? "Music")]
        let recentlyAdded = Array(albums.sorted {
            $0.addedAt == $1.addedAt ? albumOrder($0, $1) : $0.addedAt > $1.addedAt
        }.prefix(8))
        let mostPlayedAlbums = Array(albums.filter { $0.playCount > 0 }.sorted {
            $0.playCount == $1.playCount ? albumOrder($0, $1) : $0.playCount > $1.playCount
        }.prefix(8))
        let recentlyPlayed = Array(tracks.filter { $0.lastPlayedAt != nil }.sorted {
            let left = $0.lastPlayedAt ?? .distantPast
            let right = $1.lastPlayedAt ?? .distantPast
            return left == right ? TrackRecord.libraryOrder($0, $1) : left > right
        }.prefix(8))
        let mostPlayedTracks = Array(tracks.filter { $0.playCount > 0 }.sorted {
            $0.playCount == $1.playCount ? TrackRecord.libraryOrder($0, $1) : $0.playCount > $1.playCount
        }.prefix(8))
        let mostPlayedArtists = Array(artists.filter { $0.playCount > 0 }.sorted {
            $0.playCount == $1.playCount ? stringOrder($0.name, $1.name) : $0.playCount > $1.playCount
        }.prefix(8))
        try Task.checkCancellation()
        return LibrarySnapshot(sourceID: sourceID, tracks: tracks, tracksByID: tracksByID,
                               albums: albums, albumsByID: albumsByID, artists: artists, artistsByName: artistsByName,
                               yearGroups: yearGroups, genreGroups: trackGroups(genres), formatGroups: trackGroups(formats),
                               recentlyAdded: recentlyAdded, mostPlayedAlbums: mostPlayedAlbums,
                               recentlyPlayed: recentlyPlayed, mostPlayedTracks: mostPlayedTracks,
                               mostPlayedArtists: mostPlayedArtists, folderNodes: folderNodes, tracksByFolder: tracksByFolder)
    }

    private static func trackGroups(_ groups: [String: [TrackRecord]]) -> [LibraryTrackGroup] {
        groups.keys.sorted(by: stringOrder).map { LibraryTrackGroup(id: $0, title: $0, tracks: groups[$0] ?? []) }
    }

    private static func albumOrder(_ lhs: AlbumRecord, _ rhs: AlbumRecord) -> Bool {
        let title = lhs.title.localizedStandardCompare(rhs.title)
        if title != .orderedSame { return title == .orderedAscending }
        let artist = lhs.artist.localizedStandardCompare(rhs.artist)
        return artist == .orderedSame ? lhs.id < rhs.id : artist == .orderedAscending
    }

    private static func stringOrder(_ lhs: String, _ rhs: String) -> Bool {
        let order = lhs.localizedStandardCompare(rhs)
        return order == .orderedSame ? lhs < rhs : order == .orderedAscending
    }
}
