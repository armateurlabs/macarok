import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

final class LibrarySnapshotTests: XCTestCase {
    func testYearsUseResolvedAlbumYearsWithoutDuplicateOrEmptyGroups() throws {
        let tracks = [
            track("mixed-3", albumID: "mixed", year: 2002, number: 3),
            track("mixed-1", albumID: "mixed", year: nil, number: 1),
            track("mixed-2", albumID: "mixed", year: 2001, number: 2),
            track("older", albumID: "older", year: 1995),
            track("unknown", albumID: "unknown", year: nil),
            track("zero", albumID: "zero", year: 0)
        ]
        let snapshot = try LibrarySnapshot.build(sourceID: "source", tracks: tracks, sources: [source])
        XCTAssertEqual(snapshot.yearGroups.map(\.id), [2001, 1995, 0])
        XCTAssertEqual(snapshot.yearGroups.first?.albums.map(\.id), ["mixed"])
        XCTAssertEqual(snapshot.yearGroups.last?.title, "Unknown Year")
        XCTAssertNil(snapshot.yearGroups.last?.year)
        XCTAssertEqual(Set(snapshot.yearGroups.last?.albums.map(\.id) ?? []), ["unknown", "zero"])
        XCTAssertTrue(snapshot.yearGroups.allSatisfy { !$0.albums.isEmpty })
        XCTAssertEqual(Set(snapshot.yearGroups.flatMap(\.albums).map(\.id)), Set(snapshot.albums.map(\.id)))
        XCTAssertEqual(snapshot.yearGroups.flatMap(\.albums).count, snapshot.albums.count)
    }

    func testSourceIsolationAvailabilityAndDuplicateIDsAreAppliedBeforeIndexing() throws {
        var first = track("same", albumID: "album", title: "First")
        first.playCount = 7
        var duplicate = first
        duplicate.title = "Duplicate"
        var foreign = first
        foreign.sourceID = "other"
        foreign.albumID = "foreign"
        var missing = track("missing", albumID: "missing")
        missing.isAvailable = false
        let snapshot = try LibrarySnapshot.build(sourceID: source.id,
                                                  tracks: [foreign, first, duplicate, missing], sources: [source])
        XCTAssertEqual(snapshot.sourceID, source.id)
        XCTAssertEqual(snapshot.tracks.map(\.id), [first.id])
        XCTAssertEqual(snapshot.tracksByID[first.id]?.title, "First")
        XCTAssertEqual(snapshot.albumsByID.keys.sorted(), [StableID.make(source.id, "album", "album")])
        XCTAssertEqual(snapshot.artists.first?.trackCount, 1)
        XCTAssertEqual(snapshot.artists.first?.playCount, 7)
        XCTAssertEqual(snapshot.tracksByFolder[""]?.count, 1)
    }

    func testTagsFoldersAndStatisticsArePreparedForDirectDisplay() throws {
        var live = track("live", albumID: "album", year: 2005, number: 1, path: "Rock/Live/01.flac")
        live.genre = "Rock"; live.playCount = 3
        live.lastPlayedAt = Date(timeIntervalSince1970: 300)
        live.addedAt = Date(timeIntervalSince1970: 200)
        var studio = track("studio", albumID: "album", year: 2005, number: 2, path: "Rock/Studio/02.flac")
        studio.genre = ""; studio.format = "Opus"; studio.playCount = 2
        studio.lastPlayedAt = Date(timeIntervalSince1970: 400)
        studio.addedAt = Date(timeIntervalSince1970: 100)
        var sibling = track("sibling", albumID: "sibling", year: 1999, path: "Rockabilly/01.flac")
        sibling.genre = nil; sibling.format = ""
        sibling.addedAt = Date(timeIntervalSince1970: 500)
        let snapshot = try LibrarySnapshot.build(sourceID: source.id, tracks: [studio, sibling, live], sources: [source])

        XCTAssertEqual(snapshot.genreGroups.map(\.title), ["Rock", "Unknown"])
        XCTAssertEqual(snapshot.genreGroups.last?.tracks.count, 2)
        XCTAssertEqual(snapshot.formatGroups.map(\.title), ["FLAC", "Opus", "Unknown Format"])
        XCTAssertEqual(Set(snapshot.tracksByFolder["Rock"]?.map(\.id) ?? []), ["live", "studio"])
        XCTAssertEqual(snapshot.tracksByFolder["Rock/Live"]?.map(\.id), ["live"])
        XCTAssertEqual(snapshot.tracksByFolder["Rockabilly"]?.map(\.id), ["sibling"])
        XCTAssertEqual(snapshot.folderNodes.first?.name, source.name)
        XCTAssertEqual(snapshot.folderNodes.first?.children?.map(\.name), ["Rock", "Rockabilly"])
        XCTAssertEqual(snapshot.recentlyAdded.first?.id, "sibling")
        XCTAssertEqual(snapshot.mostPlayedAlbums.first?.playCount, 5)
        XCTAssertEqual(snapshot.recentlyPlayed.map(\.id), ["studio", "live"])
        XCTAssertEqual(snapshot.mostPlayedTracks.map(\.id), ["live", "studio"])
        XCTAssertEqual(snapshot.mostPlayedArtists.first?.playCount, 5)
        XCTAssertEqual(snapshot.artistsByName["artist"]?.albums.count, 2)
    }

    func testGroupOrderingIsDeterministicAcrossInputOrders() throws {
        let tracks = [
            track("b", albumID: "second", title: "Same", year: 2000),
            track("a", albumID: "first", title: "Same", year: 2000),
            track("c", albumID: "third", title: "Same", year: 2000)
        ].map { value -> TrackRecord in
            var value = value
            value.album = "Same Album"
            value.addedAt = Date(timeIntervalSince1970: 10)
            value.playCount = 1
            return value
        }
        let first = try LibrarySnapshot.build(sourceID: source.id, tracks: tracks, sources: [source])
        let reversed = try LibrarySnapshot.build(sourceID: source.id, tracks: Array(tracks.reversed()), sources: [source])
        XCTAssertEqual(first.tracks.map(\.id), reversed.tracks.map(\.id))
        XCTAssertEqual(first.albums.map(\.id), ["first", "second", "third"])
        XCTAssertEqual(first.albums.map(\.id), reversed.albums.map(\.id))
        XCTAssertEqual(first.recentlyAdded.map(\.id), reversed.recentlyAdded.map(\.id))
        XCTAssertEqual(first.mostPlayedAlbums.map(\.id), reversed.mostPlayedAlbums.map(\.id))
        XCTAssertEqual(first.yearGroups.first?.albums.map(\.id), reversed.yearGroups.first?.albums.map(\.id))
    }

    func testLargeCatalogBuildsAllGroupsOnceWithoutPerYearCatalogTraversal() throws {
        let tracks = (0..<50_000).map { index -> TrackRecord in
            let album = index / 10
            return TrackRecord(id: "track-\(index)", sourceID: source.id, albumID: "album-\(album)",
                               title: "Track \(index % 10)", artist: "Artist \(album % 500)",
                               album: "Album \(album)", year: 1900 + album % 100, genre: "Genre \(album % 12)",
                               trackNumber: index % 10 + 1, duration: 180,
                               remoteID: String(index), remotePath: "Artist \(album % 500)/Album \(album)/\(index).flac", format: "FLAC")
        }
        let started = ContinuousClock().now
        let snapshot = try LibrarySnapshot.build(sourceID: source.id, tracks: tracks, sources: [source])
        let elapsed = started.duration(to: ContinuousClock().now)
        XCTAssertEqual(snapshot.tracks.count, 50_000)
        XCTAssertEqual(snapshot.albums.count, 5_000)
        XCTAssertEqual(snapshot.artists.count, 500)
        XCTAssertEqual(snapshot.yearGroups.count, 100)
        XCTAssertEqual(snapshot.yearGroups.reduce(0) { $0 + $1.albums.count }, 5_000)
        XCTAssertEqual(snapshot.genreGroups.reduce(0) { $0 + $1.tracks.count }, 50_000)
        XCTAssertEqual(snapshot.tracksByFolder[""]?.count, 50_000)
        XCTAssertLessThan(elapsed, .seconds(8), "Snapshot building must not scan the complete catalog separately for every year.")
        print("Built presentation snapshot for 50,000 tracks, 5,000 albums, and 100 years in \(elapsed).")
    }

    func testAlreadyCancelledBuildStopsBeforeProducingPresentationData() async throws {
        let gate = SnapshotBuildGate()
        let task = Task.detached {
            await gate.wait()
            return try LibrarySnapshot.build(sourceID: "source", tracks: [], sources: [])
        }
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("Cancelled builders must not publish presentation data.") }
        catch is CancellationError { }
    }

    private var source: SourceRecord {
        SourceRecord(id: "source", kind: .openSubsonic, name: "Test Server", location: "https://music.invalid")
    }

    func testSortDirectionReordersBrowsingListsAndSurvivesPatchesAndRebuilds() throws {
        func item(_ id: String, artist: String, album: String, year: Int?, genre: String, path: String) -> TrackRecord {
            TrackRecord(id: id, sourceID: source.id, albumID: album, title: id, artist: artist, album: album, year: year,
                        genre: genre, trackNumber: 1, duration: 60, remoteID: id, remotePath: path, format: "FLAC")
        }
        var tracks = [
            item("a", artist: "Artist 2", album: "Album 10", year: 2001, genre: "Rock", path: "B/Album 10/a.flac"),
            item("b", artist: "Artist 10", album: "Album 2", year: 1990, genre: "Jazz", path: "A/Album 2/b.flac"),
            item("c", artist: "artist 1", album: "Album 1", year: nil, genre: "Ambient", path: "A/Album 1/c.flac")
        ]
        tracks[0].playCount = 4
        let ascending = try LibrarySnapshot.build(sourceID: source.id, tracks: tracks, sources: [source])
        XCTAssertEqual(ascending.presentation.artists.map(\.name), ["artist 1", "Artist 2", "Artist 10"])
        XCTAssertEqual(ascending.presentation.yearGroups.map(\.id), [2001, 1990, 0], "Years keep newest first by default.")

        var order = LibrarySortOrder()
        for key in LibrarySortKey.allCases { order.toggle(key) }
        let reversed = try ascending.sorted(order)
        XCTAssertEqual(reversed.presentation.artists.map(\.name), ["Artist 10", "Artist 2", "artist 1"])
        XCTAssertEqual(reversed.presentation.albums.map(\.title), ["Album 10", "Album 2", "Album 1"])
        XCTAssertEqual(reversed.presentation.yearGroups.map(\.id), [1990, 2001, 0], "Unknown Year stays last.")
        XCTAssertEqual(reversed.presentation.genreGroups.map(\.title), ["Rock", "Jazz", "Ambient"])
        XCTAssertEqual(reversed.presentation.folderNodes.first?.children?.map(\.name), ["B", "A"])
        XCTAssertEqual(reversed.presentation.folderNodes.first?.children?.last?.children?.map(\.name), ["Album 2", "Album 1"])
        XCTAssertEqual(reversed.artists.map(\.name), ascending.artists.map(\.name), "Canonical order feeds rankings and patches.")
        XCTAssertEqual(reversed.albumsByID[StableID.make(source.id, "album", "Album 1")]?.tracks.map(\.id), ["c"])
        XCTAssertEqual(reversed.mostPlayedAlbums.map(\.id), ascending.mostPlayedAlbums.map(\.id))

        var rated = tracks[1]; rated.rating = 5; rated.playCount = 9
        let patched = try reversed.updating(updatedTracks: [rated], sources: [source])
        XCTAssertEqual(patched.presentation.order, order)
        XCTAssertEqual(patched.presentation.artists.map(\.name), ["Artist 10", "Artist 2", "artist 1"])
        XCTAssertEqual(patched.presentation.albums.first { $0.id == "Album 2" }?.playCount, 9)
        var renamed = tracks[2]; renamed.artist = "Zed"; renamed.albumArtist = "Zed"; renamed.album = "Zed Album"; renamed.albumID = "Zed Album"
        let rebuilt = try patched.updating(updatedTracks: [renamed], sources: [source])
        XCTAssertEqual(rebuilt.presentation.artists.map(\.name), ["Zed", "Artist 10", "Artist 2"])
        XCTAssertEqual(try rebuilt.sorted(LibrarySortOrder()).presentation.artists.map(\.name), ["Artist 2", "Artist 10", "Zed"])
    }

    private func track(_ id: String, albumID: String, title: String? = nil, year: Int? = nil,
                       number: Int = 1, path: String? = nil) -> TrackRecord {
        TrackRecord(id: id, sourceID: source.id, albumID: albumID, title: title ?? id, artist: "Artist",
                    album: "Album \(albumID)", year: year, trackNumber: number, duration: 120,
                    remoteID: id, remotePath: path ?? "Artist/Album \(albumID)/\(id).flac", format: "FLAC")
    }
}

private actor SnapshotBuildGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if !isOpen { await withCheckedContinuation { continuation = $0 } }
    }
    func open() { isOpen = true; continuation?.resume(); continuation = nil }
}
