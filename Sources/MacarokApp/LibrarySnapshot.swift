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
        self.init(name: name, orderedAlbums: albums.sorted {
            if ($0.year ?? 0) != ($1.year ?? 0) { return ($0.year ?? 0) < ($1.year ?? 0) }
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.presentationID < $1.presentationID : order == .orderedAscending
        })
    }

    fileprivate init(name: String, orderedAlbums albums: [AlbumRecord]) {
        self.id = StableID.make("artist", Self.normalizedName(name))
        self.name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.albums = albums
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
    let stations: [TrackRecord]
    /// Episodes of podcast sources in scope, newest first. All Sources keeps them out of the music
    /// lists above; lookups by track or album identity still resolve them.
    let podcastEpisodes: [TrackRecord]
    /// Browsing lists in the user's chosen direction; the fields above keep canonical order.
    let presentation: LibraryPresentation

    static let empty = LibrarySnapshot(scope: nil, tracks: [], tracksByID: [:], albums: [], albumsByID: [:],
                                       artists: [], artistsByName: [:], yearGroups: [], genreGroups: [], formatGroups: [],
                                       recentlyAdded: [], mostPlayedAlbums: [], recentlyPlayed: [], mostPlayedTracks: [],
                                       mostPlayedArtists: [], folderNodes: [], tracksByFolder: [:], folderTitles: [:], stations: [],
                                       podcastEpisodes: [], presentation: .empty)

    static func build(sourceID: String, tracks: [TrackRecord], sources: [SourceRecord]) throws -> LibrarySnapshot {
        try build(scope: .source(sourceID), tracks: tracks, sources: sources)
    }

    /// Reorders only the browsing presentation; canonical data, rankings, and lookups are reused.
    func sorted(_ order: LibrarySortOrder) throws -> LibrarySnapshot {
        try Task.checkCancellation()
        guard order != presentation.order else { return self }
        return replacing(presentation: presentation(order))
    }

    private func presentation(_ order: LibrarySortOrder) -> LibraryPresentation {
        LibraryPresentation(order: order, artists: artists, albums: albums, yearGroups: yearGroups,
                            genreGroups: genreGroups, formatGroups: formatGroups, folderNodes: folderNodes)
    }

    private func replacing(presentation: LibraryPresentation) -> LibrarySnapshot {
        LibrarySnapshot(scope: scope, tracks: tracks, tracksByID: tracksByID, albums: albums, albumsByID: albumsByID,
            artists: artists, artistsByName: artistsByName, yearGroups: yearGroups, genreGroups: genreGroups,
            formatGroups: formatGroups, recentlyAdded: recentlyAdded, mostPlayedAlbums: mostPlayedAlbums,
            recentlyPlayed: recentlyPlayed, mostPlayedTracks: mostPlayedTracks, mostPlayedArtists: mostPlayedArtists,
            folderNodes: folderNodes, tracksByFolder: tracksByFolder, folderTitles: folderTitles, stations: stations,
            podcastEpisodes: podcastEpisodes, presentation: presentation)
    }

    static func build(scope: LibraryScope, tracks input: [TrackRecord], sources: [SourceRecord],
                      sortOrder: LibrarySortOrder = LibrarySortOrder()) throws -> LibrarySnapshot {
        try Task.checkCancellation()
        let visibleSources = sources.filter { scope.includes($0) }
        let registeredIDs = Set(visibleSources.map(\.id))
        let radioIDs = Set(visibleSources.filter { $0.kind == .radio }.map(\.id))
        let podcastIDs = Set(visibleSources.filter { $0.kind.isPodcast }.map(\.id))
        // All Sources browses music only; podcasts have their own library tab and Home sections.
        let separatesPodcasts = (scope == .all || scope == .podcasts) && !podcastIDs.isEmpty
        let musicSources = visibleSources.filter { $0.kind != .radio && !(separatesPodcasts && $0.kind.isPodcast) }
        var seen: Set<String> = []
        var tracks: [TrackRecord] = []
        var stations: [TrackRecord] = []
        var separatedEpisodes: [TrackRecord] = []
        tracks.reserveCapacity(input.count)
        for (index, track) in input.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard registeredIDs.contains(track.sourceID),
                  track.isAvailable, seen.insert(track.id).inserted else { continue }
            if radioIDs.contains(track.sourceID) { stations.append(track) }
            else if separatesPodcasts && podcastIDs.contains(track.sourceID) { separatedEpisodes.append(track) }
            else { tracks.append(track) }
        }
        tracks = try tracks.sorted { try Task.checkCancellation(); return TrackRecord.libraryOrder($0, $1) }
        try orderPodcastEpisodes(&tracks, sourceIDs: podcastIDs)
        try Task.checkCancellation()
        // Directory previews stay playable through tracksByID but are not part of the shows you follow.
        let podcastEpisodes = PodcastLibrary.ordered((separatesPodcasts ? separatedEpisodes : tracks.filter { podcastIDs.contains($0.sourceID) })
            .filter { $0.sourceID != PodcastDirectorySource.sourceID })

        var tracksByID = Dictionary(uniqueKeysWithValues: stations.map { ($0.id, $0) })
        for episode in separatedEpisodes { tracksByID[episode.id] = episode }
        var albumTracks: [LibraryAlbumKey: [TrackRecord]] = [:]
        var genres: [String: [TrackRecord]] = [:]
        var formats: [String: [TrackRecord]] = [:]
        var tracksByFolder: [String: [TrackRecord]] = ["": tracks]
        var folderNames: [String: String] = [:]
        var childFolders: [String: [String]] = [:]
        let resolver = LibraryFolderPathResolver(sources: musicSources)
        let allSources = scope == .all
        let sourceRootIDs = Dictionary(uniqueKeysWithValues: musicSources.map { ($0.id, "source:" + StableID.make($0.id)) })
        func rootKey(_ sourceID: String) -> String { allSources ? sourceRootIDs[sourceID, default: ""] : "" }
        for source in musicSources {
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
        if separatesPodcasts {
            for values in Dictionary(grouping: podcastEpisodes, by: { LibraryAlbumKey(sourceID: $0.sourceID, albumID: $0.albumID) }).values {
                let album = AlbumRecord(orderedTracks: values)
                albumsByID[album.presentationID] = album
            }
        }
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
            folderNodes = try musicSources.map { try folder(rootKey($0.id), name: $0.name) }
        } else {
            folderNodes = musicSources.isEmpty ? [] : [try folder("", name: musicSources.first?.name ?? "Music")]
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
        let genreGroups = trackGroups(genres), formatGroups = trackGroups(formats)
        try Task.checkCancellation()
        let presentation = LibraryPresentation(order: sortOrder, artists: artists, albums: albums, yearGroups: yearGroups,
                                               genreGroups: genreGroups, formatGroups: formatGroups, folderNodes: folderNodes)
        return LibrarySnapshot(scope: scope, tracks: tracks, tracksByID: tracksByID, albums: albums, albumsByID: albumsByID,
                               artists: artists, artistsByName: artistsByName, yearGroups: yearGroups,
                               genreGroups: genreGroups, formatGroups: formatGroups, recentlyAdded: recentlyAdded,
                               mostPlayedAlbums: mostPlayedAlbums, recentlyPlayed: recentlyPlayed, mostPlayedTracks: mostPlayedTracks,
                               mostPlayedArtists: mostPlayedArtists, folderNodes: folderNodes, tracksByFolder: tracksByFolder,
                               folderTitles: folderNames, stations: stations.sorted { stringOrder($0.title, $1.title) },
                               podcastEpisodes: podcastEpisodes, presentation: presentation)
    }

    /// Patch frequently changing values without SQL reads, regrouping, or localized sorting.
    /// Structural edits use the already cached complete track set as their rebuild input.
    func updating(updatedTracks: [TrackRecord], sources: [SourceRecord]) throws -> LibrarySnapshot {
        try Task.checkCancellation()
        guard let scope else { return self }
        let visibleSources = sources.filter { scope.includes($0) }
        let registered = Set(visibleSources.map(\.id))
        let radioSources = Set(visibleSources.filter { $0.kind == .radio }.map(\.id))
        let podcastSources = Set(visibleSources.filter { $0.kind.isPodcast }.map(\.id))
        var updates: [String: TrackRecord] = [:]
        var radioUpdates: [TrackRecord] = []
        var structural = false
        for track in updatedTracks where registered.contains(track.sourceID) {
            try Task.checkCancellation()
            if radioSources.contains(track.sourceID) { radioUpdates.append(track); continue }
            // Separated episodes live outside the music arrays patched below.
            if scope == .all || scope == .podcasts, podcastSources.contains(track.sourceID) { structural = true }
            // Stored track identities belong to one origin, including duplicated albums/titles.
            if let previous = tracksByID[track.id], previous.sourceID != track.sourceID { continue }
            if let previous = tracksByID[track.id] {
                var unchangedStructure = track
                unchangedStructure.playCount = previous.playCount
                unchangedStructure.lastPlayedAt = previous.lastPlayedAt
                unchangedStructure.rating = previous.rating
                unchangedStructure.artworkPath = previous.artworkPath
                unchangedStructure.metadataLocked = previous.metadataLocked
                if unchangedStructure != previous { structural = true }
            } else { structural = true }
            updates[track.id] = track
        }
        if structural {
            var merged = tracksByID
            for (id, track) in updates { merged[id] = track }
            for track in radioUpdates { merged[track.id] = track }
            return try Self.build(scope: scope, tracks: Array(merged.values), sources: sources, sortOrder: presentation.order)
        }
        guard !updates.isEmpty else { return try updatingStations(radioUpdates, sources: sources) }

        func patchedTracks(_ values: [TrackRecord]) throws -> [TrackRecord] {
            var result = values
            for (index, value) in values.enumerated() {
                if index.isMultiple(of: 512) { try Task.checkCancellation() }
                if let update = updates[value.id] { result[index] = update }
            }
            return result
        }
        let tracks = try patchedTracks(self.tracks)
        var tracksByID = self.tracksByID
        var affectedAlbums = Set<String>()
        for track in updates.values {
            tracksByID[track.id] = track
            affectedAlbums.insert(StableID.make(track.sourceID, "album", track.albumID))
        }
        var albumsByID = self.albumsByID
        let albums = try self.albums.map { album -> AlbumRecord in
            guard affectedAlbums.contains(album.presentationID) else { return album }
            let updated = AlbumRecord(orderedTracks: try patchedTracks(album.tracks))
            albumsByID[updated.presentationID] = updated
            return updated
        }
        let artists = try self.artists.map { artist -> LibraryArtistGroup in
            try Task.checkCancellation()
            guard artist.albums.contains(where: { affectedAlbums.contains($0.presentationID) }) else { return artist }
            return LibraryArtistGroup(name: artist.name, orderedAlbums: artist.albums.map { albumsByID[$0.presentationID] ?? $0 })
        }
        let artistsByName = Dictionary(uniqueKeysWithValues: artists.map { (LibraryArtistGroup.normalizedName($0.name), $0) })
        let years = yearGroups.map { group in
            LibraryYearGroup(id: group.id, year: group.year, title: group.title,
                albums: group.albums.map { albumsByID[$0.presentationID] ?? $0 })
        }
        // Only arrays containing changed tracks need copy-on-write. In a deep library, walking
        // every folder's complete descendants multiplied the work by the entire tree depth.
        let affectedGenres = Set(updates.values.map { $0.genre.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown" })
        let affectedFormats = Set(updates.values.map { $0.format.isEmpty ? "Unknown Format" : $0.format })
        func groups(_ values: [LibraryTrackGroup], affected: Set<String>) throws -> [LibraryTrackGroup] {
            try values.map { group in
                guard affected.contains(group.id) else { return group }
                return LibraryTrackGroup(id: group.id, title: group.title, tracks: try patchedTracks(group.tracks))
            }
        }
        let resolver = LibraryFolderPathResolver(sources: visibleSources.filter { $0.kind != .radio })
        var affectedFolders: Set<String> = [""]
        for track in updates.values {
            var parent = scope == .all ? "source:" + StableID.make(track.sourceID) : ""
            affectedFolders.insert(parent)
            for component in resolver.folderPath(track).split(separator: "/") {
                parent = parent.isEmpty ? String(component) : parent + "/" + String(component)
                affectedFolders.insert(parent)
            }
        }
        var folders = tracksByFolder
        folders[""] = tracks
        for key in affectedFolders where !key.isEmpty {
            try Task.checkCancellation()
            if let values = tracksByFolder[key] { folders[key] = try patchedTracks(values) }
        }
        let genres = try groups(genreGroups, affected: affectedGenres)
        let formats = try groups(formatGroups, affected: affectedFormats)
        // Patched values keep their canonical positions, so the same direction is re-derived in linear time.
        let presentation = LibraryPresentation(order: presentation.order, artists: artists, albums: albums, yearGroups: years,
                                               genreGroups: genres, formatGroups: formats, folderNodes: folderNodes)
        let updated = LibrarySnapshot(scope: scope, tracks: tracks, tracksByID: tracksByID,
            albums: albums, albumsByID: albumsByID, artists: artists, artistsByName: artistsByName,
            yearGroups: years, genreGroups: genres, formatGroups: formats,
            recentlyAdded: recentlyAdded.map { albumsByID[$0.presentationID] ?? $0 },
            mostPlayedAlbums: try Self.topRanked(albums, eligible: { $0.playCount > 0 }, before: { $0.playCount > $1.playCount }),
            recentlyPlayed: try Self.topRanked(tracks, eligible: { $0.lastPlayedAt != nil }, before: { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }),
            mostPlayedTracks: try Self.topRanked(tracks, eligible: { $0.playCount > 0 }, before: { $0.playCount > $1.playCount }),
            mostPlayedArtists: try Self.topRanked(artists, eligible: { $0.playCount > 0 }, before: { $0.playCount > $1.playCount }),
            folderNodes: folderNodes, tracksByFolder: folders, folderTitles: folderTitles, stations: stations,
            podcastEpisodes: try patchedTracks(podcastEpisodes), presentation: presentation)
        return try updated.updatingStations(radioUpdates, sources: sources)
    }

    /// Radio changes must not rebuild the music catalog or introduce stations into its statistics.
    func updatingStations(_ updatedStations: [TrackRecord], removingIDs: Set<String> = [], sources: [SourceRecord]) throws -> LibrarySnapshot {
        try Task.checkCancellation()
        guard let scope else { return self }
        let radioSources = Set(sources.filter { $0.kind == .radio && scope.includes($0) }.map(\.id))
        if updatedStations.isEmpty, removingIDs.isEmpty, stations.allSatisfy({ radioSources.contains($0.sourceID) }) { return self }
        var indexed = Dictionary(uniqueKeysWithValues: stations.filter {
            radioSources.contains($0.sourceID) && !removingIDs.contains($0.id)
        }.map { ($0.id, $0) })
        for track in updatedStations where radioSources.contains(track.sourceID) {
            try Task.checkCancellation()
            // Do not replace a music copy if an invalid caller supplies a colliding station ID.
            guard tracksByID[track.id].map({ radioSources.contains($0.sourceID) }) ?? true else { continue }
            if let previous = tracksByID[track.id], previous.sourceID != track.sourceID { continue }
            if track.isAvailable { indexed[track.id] = track }
            else { indexed[track.id] = nil }
        }
        let stations = try indexed.values.sorted { try Task.checkCancellation(); return Self.stringOrder($0.title, $1.title) }
        var tracksByID = self.tracksByID
        for station in self.stations { tracksByID[station.id] = nil }
        for station in stations { tracksByID[station.id] = station }
        return LibrarySnapshot(scope: scope, tracks: tracks, tracksByID: tracksByID,
            albums: albums, albumsByID: albumsByID, artists: artists, artistsByName: artistsByName,
            yearGroups: yearGroups, genreGroups: genreGroups, formatGroups: formatGroups,
            recentlyAdded: recentlyAdded, mostPlayedAlbums: mostPlayedAlbums, recentlyPlayed: recentlyPlayed,
            mostPlayedTracks: mostPlayedTracks, mostPlayedArtists: mostPlayedArtists,
            folderNodes: folderNodes, tracksByFolder: tracksByFolder, folderTitles: folderTitles, stations: stations,
            podcastEpisodes: podcastEpisodes, presentation: presentation)
    }

    /// Input is already in the library's deterministic display order, which supplies every tie break.
    private static func topRanked<Value>(_ values: [Value], eligible: (Value) -> Bool,
                                         before: (Value, Value) -> Bool) throws -> [Value] {
        var result: [Value] = []
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 512) { try Task.checkCancellation() }
            guard eligible(value) else { continue }
            let insertion = result.firstIndex { before(value, $0) } ?? result.count
            guard insertion < 8 else { continue }
            result.insert(value, at: insertion)
            if result.count > 8 { result.removeLast() }
        }
        return result
    }

    private static func trackGroups(_ groups: [String: [TrackRecord]]) -> [LibraryTrackGroup] {
        groups.keys.sorted(by: stringOrder).map { LibraryTrackGroup(id: $0, title: $0, tracks: groups[$0] ?? []) }
    }

    private static func orderPodcastEpisodes(_ tracks: inout [TrackRecord], sourceIDs: Set<String>) throws {
        guard !sourceIDs.isEmpty else { return }
        var positions: [LibraryAlbumKey: [Int]] = [:]
        for (index, track) in tracks.enumerated() where sourceIDs.contains(track.sourceID) {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            positions[LibraryAlbumKey(sourceID: track.sourceID, albumID: track.albumID), default: []].append(index)
        }
        for indices in positions.values where indices.count > 1 {
            try Task.checkCancellation()
            let episodes = try indices.map { tracks[$0] }.sorted { left, right in
                try Task.checkCancellation()
                // Podcast import stores publication time in addedAt; year is absent when the
                // publisher supplied no date, whose addedAt instead records the import time.
                if (left.year == nil) != (right.year == nil) { return left.year != nil }
                if left.year != nil, left.addedAt != right.addedAt { return left.addedAt > right.addedAt }
                let title = left.title.localizedStandardCompare(right.title)
                return title == .orderedSame ? left.id < right.id : title == .orderedAscending
            }
            // Replace only this feed's slots. Music ordering and interleaved source copies keep
            // their exact positions, while every view derives the same newest-first feed order.
            for (index, episode) in zip(indices, episodes) { tracks[index] = episode }
        }
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
