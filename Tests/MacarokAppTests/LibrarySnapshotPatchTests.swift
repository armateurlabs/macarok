import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

final class LibrarySnapshotPatchTests: XCTestCase {
    func testStatisticsAndArtworkPatchEveryPresentationWhileKeepingOrderAndFolderIdentities() throws {
        let origins = sources
        let tracks = (0..<12).map { index in
            TrackRecord(id: "track-\(index)", sourceID: index.isMultiple(of: 2) ? "first" : "second", albumID: "album-\(index)",
                title: "Track \(index)", artist: "Artist \(index)", album: "Album \(index)", year: 2000 + index,
                genre: "Genre", trackNumber: 1, duration: 180, remotePath: "Shared/Album/Track \(index).flac", format: "FLAC",
                addedAt: Date(timeIntervalSince1970: Double(index)), playCount: 12 - index)
        }
        let original = try LibrarySnapshot.build(scope: .all, tracks: tracks, sources: origins)
        var update = try XCTUnwrap(original.tracksByID["track-11"])
        XCTAssertFalse(original.mostPlayedTracks.contains { $0.id == update.id })
        update.playCount = 100
        update.lastPlayedAt = Date(timeIntervalSince1970: 5_000)
        update.rating = 5
        update.artworkPath = "/cache/new-cover.jpg"
        let patched = try original.updating(updatedTracks: [update], sources: origins)
        let rebuilt = try LibrarySnapshot.build(scope: .all, tracks: tracks.map { $0.id == update.id ? update : $0 }, sources: origins)

        XCTAssertEqual(patched.tracks.map(\.id), original.tracks.map(\.id))
        XCTAssertEqual(patched.albums.map(\.presentationID), original.albums.map(\.presentationID))
        XCTAssertEqual(patched.artists.map(\.id), original.artists.map(\.id))
        XCTAssertEqual(patched.folderNodes, original.folderNodes)
        XCTAssertEqual(patched.folderTitles, original.folderTitles)
        XCTAssertEqual(patched.mostPlayedTracks.map(\.id), rebuilt.mostPlayedTracks.map(\.id))
        XCTAssertEqual(patched.mostPlayedAlbums.map(\.presentationID), rebuilt.mostPlayedAlbums.map(\.presentationID))
        XCTAssertEqual(patched.mostPlayedArtists.map(\.id), rebuilt.mostPlayedArtists.map(\.id))
        XCTAssertEqual(patched.recentlyPlayed.first, update)
        XCTAssertEqual(patched.mostPlayedTracks.first, update)
        XCTAssertEqual(patched.mostPlayedAlbums.first?.artworkPath, update.artworkPath)
        XCTAssertEqual(patched.mostPlayedArtists.first?.artworkPath, update.artworkPath)
        XCTAssertEqual(patched.genreGroups.first?.tracks.first { $0.id == update.id }, update)
        XCTAssertEqual(patched.formatGroups.first?.tracks.first { $0.id == update.id }, update)
        XCTAssertEqual(patched.yearGroups.first?.albums.first?.tracks.first, update)
        for values in patched.tracksByFolder.values where values.contains(where: { $0.id == update.id }) {
            XCTAssertEqual(values.first { $0.id == update.id }, update)
        }
        XCTAssertEqual(original.tracksByID[update.id]?.playCount, 1, "Patching must not mutate an in-flight snapshot.")
    }

    func testDuplicateAlbumCopiesRemainSourceSpecificAndNormalizedArtistStatisticsAggregate() throws {
        let first = TrackRecord(id: "first-copy", sourceID: "first", albumID: "same-raw-album", title: "Same song",
            artist: "Shared Artist", album: "Same album", genre: "Rock", duration: 180, remotePath: "Shared/Album/Song.flac", format: "FLAC", playCount: 2)
        let second = TrackRecord(id: "second-copy", sourceID: "second", albumID: "same-raw-album", title: "Same song",
            artist: " shared  artist ", album: "Same album", genre: "Rock", duration: 180, remotePath: "Shared/Album/Song.flac", format: "FLAC", playCount: 3)
        let original = try LibrarySnapshot.build(scope: .all, tracks: [first, second], sources: sources)
        var update = second
        update.playCount = 9
        update.artworkPath = "/second-library/new-cover.jpg"
        let patched = try original.updating(updatedTracks: [update], sources: sources)

        XCTAssertEqual(patched.tracksByID[first.id], first)
        XCTAssertEqual(patched.tracksByID[second.id], update)
        XCTAssertEqual(patched.albumsByID[StableID.make("first", "album", first.albumID)]?.artworkPath, nil)
        XCTAssertEqual(patched.albumsByID[StableID.make("second", "album", second.albumID)]?.artworkPath, update.artworkPath)
        XCTAssertEqual(patched.albums.count, 2)
        XCTAssertEqual(patched.artists.count, 1)
        XCTAssertEqual(patched.mostPlayedArtists.first?.playCount, 11)
        XCTAssertEqual(patched.artists.first?.sourceIDs, Set(["first", "second"]))
        XCTAssertNotEqual(patched.folderNodes.first?.id, patched.folderNodes.last?.id)

        let scoped = try LibrarySnapshot.build(sourceID: "first", tracks: [first, second], sources: sources)
        let unchanged = try scoped.updating(updatedTracks: [update], sources: sources)
        XCTAssertEqual(unchanged.tracks, [first])
        XCTAssertEqual(unchanged.mostPlayedArtists.first?.playCount, 2)
    }

    func testStructuralChangesRebuildOnlyFromTheExistingInMemoryTracks() throws {
        let first = TrackRecord(id: "first", sourceID: "first", title: "Original", artist: "Artist", album: "Original Album",
            year: 1990, genre: "Rock", duration: 30, remotePath: "Old/Original.flac", format: "FLAC")
        let sibling = TrackRecord(id: "sibling", sourceID: "second", title: "Sibling", artist: "Other", album: "Other", duration: 40)
        let snapshot = try LibrarySnapshot.build(scope: .all, tracks: [first, sibling], sources: sources)
        var update = first
        update.title = "Corrected"
        update.artist = "Changed Artist"
        update.albumArtist = "Changed Artist"
        update.album = "Corrected Album"
        update.albumID = "corrected-album"
        update.year = 2026
        update.genre = "Jazz"
        update.remotePath = "New/Corrected.flac"
        let patched = try snapshot.updating(updatedTracks: [update], sources: sources)
        let rebuilt = try LibrarySnapshot.build(scope: .all, tracks: [update, sibling], sources: sources)
        XCTAssertEqual(patched.tracks, rebuilt.tracks)
        XCTAssertEqual(patched.albums.map(\.presentationID), rebuilt.albums.map(\.presentationID))
        XCTAssertEqual(patched.yearGroups.map(\.id), rebuilt.yearGroups.map(\.id))
        XCTAssertEqual(patched.genreGroups.map(\.title), rebuilt.genreGroups.map(\.title))
        XCTAssertEqual(patched.folderNodes, rebuilt.folderNodes)

        var unavailable = update
        unavailable.isAvailable = false
        let removed = try patched.updating(updatedTracks: [unavailable], sources: sources)
        XCTAssertEqual(removed.tracks, [sibling])
        XCTAssertNil(removed.tracksByID[update.id])
    }

    func testRadioPatchesAddRenameAndRemoveStationsWithoutTouchingMusicRankings() throws {
        let music = TrackRecord(id: "song", sourceID: "first", title: "Song", duration: 180, playCount: 2)
        let station = TrackRecord(id: "station", sourceID: "radio", title: "Original station", duration: 0, playCount: 10_000)
        let snapshot = try LibrarySnapshot.build(scope: .all, tracks: [music, station], sources: sources)
        var renamed = station
        renamed.title = "Renamed station"
        let added = TrackRecord(id: "new-station", sourceID: "radio", title: "Added station", duration: 0, playCount: 20_000)
        let patched = try snapshot.updatingStations([renamed, added], sources: sources)
        XCTAssertEqual(patched.stations.map(\.title), ["Added station", "Renamed station"])
        XCTAssertEqual(patched.tracks, snapshot.tracks)
        XCTAssertEqual(patched.folderNodes, snapshot.folderNodes)
        XCTAssertEqual(patched.mostPlayedTracks, snapshot.mostPlayedTracks)
        XCTAssertEqual(patched.mostPlayedAlbums.map(\.presentationID), snapshot.mostPlayedAlbums.map(\.presentationID))
        XCTAssertEqual(patched.artists.map(\.id), snapshot.artists.map(\.id))
        XCTAssertEqual(patched.tracksByID[renamed.id]?.title, renamed.title)
        let removed = try patched.updatingStations([], removingIDs: [renamed.id], sources: sources)
        XCTAssertEqual(removed.stations, [added])
        XCTAssertNil(removed.tracksByID[renamed.id])
        XCTAssertEqual(removed.tracksByID[music.id], music)
        var unavailable = added
        unavailable.isAvailable = false
        XCTAssertTrue(try removed.updating(updatedTracks: [unavailable], sources: sources).stations.isEmpty)
    }

    func testRankTiesAndHistoryRemovalMatchACompleteBuild() throws {
        let tracks = (0..<16).map { index in
            TrackRecord(id: "track-\(index)", sourceID: "first", title: "Track \(index)", artist: "Artist \(index)",
                album: "Album \(index)", duration: 30, lastPlayedAt: Date(timeIntervalSince1970: 1_000), playCount: 2)
        }
        let snapshot = try LibrarySnapshot.build(scope: .all, tracks: tracks, sources: sources)
        var update = try XCTUnwrap(snapshot.recentlyPlayed.first)
        update.lastPlayedAt = nil
        update.playCount = 0
        let patched = try snapshot.updating(updatedTracks: [update], sources: sources)
        let rebuilt = try LibrarySnapshot.build(scope: .all, tracks: tracks.map { $0.id == update.id ? update : $0 }, sources: sources)
        XCTAssertEqual(patched.recentlyPlayed, rebuilt.recentlyPlayed)
        XCTAssertEqual(patched.mostPlayedTracks, rebuilt.mostPlayedTracks)
        XCTAssertEqual(patched.mostPlayedAlbums.map(\.presentationID), rebuilt.mostPlayedAlbums.map(\.presentationID))
        XCTAssertEqual(patched.mostPlayedArtists.map(\.id), rebuilt.mostPlayedArtists.map(\.id))
    }

    func testLargeHistoryPatchRetainsCompletePreparedCatalog() throws {
        let tracks = (0..<50_000).map { index in
            TrackRecord(id: "track-\(index)", sourceID: index.isMultiple(of: 2) ? "first" : "second", albumID: "album-\(index / 10)",
                title: "Track \(index % 10)", artist: "Artist \(index / 100)", album: "Album \(index / 10)", year: 2000,
                genre: "Genre", trackNumber: index % 10 + 1, duration: 180, remotePath: "Artist/Album \(index / 10)/\(index).flac", format: "FLAC")
        }
        let snapshot = try LibrarySnapshot.build(scope: .all, tracks: tracks, sources: sources)
        var updated = try XCTUnwrap(snapshot.tracksByID["track-49999"])
        updated.playCount = 1
        updated.lastPlayedAt = Date()
        let started = ContinuousClock().now
        let patched = try snapshot.updating(updatedTracks: [updated], sources: sources)
        let elapsed = started.duration(to: ContinuousClock().now)
        XCTAssertEqual(patched.tracks.count, 50_000)
        XCTAssertEqual(patched.folderNodes, snapshot.folderNodes)
        XCTAssertEqual(patched.mostPlayedTracks, [updated])
        // A history-only patch must reuse prepared topology and unaffected groups. Checking
        // nonempty copy-on-write buffers catches a full rebuild without a runner-speed budget.
        assertSharesStorage(patched.folderNodes, snapshot.folderNodes, "A history patch must reuse the prepared folder tree.")
        let unaffectedAlbumID = StableID.make("first", "album", "album-0")
        let originalAlbum = try XCTUnwrap(snapshot.albumsByID[unaffectedAlbumID])
        let patchedAlbum = try XCTUnwrap(patched.albumsByID[unaffectedAlbumID])
        assertSharesStorage(patchedAlbum.tracks, originalAlbum.tracks, "A history patch must not rebuild unaffected albums.")
        let originalArtist = try XCTUnwrap(snapshot.artistsByName["artist 0"])
        let patchedArtist = try XCTUnwrap(patched.artistsByName["artist 0"])
        assertSharesStorage(patchedArtist.albums, originalArtist.albums, "A history patch must not regroup unaffected artists.")
        let unaffectedFolderID = "source:" + StableID.make("first")
        let originalFolderTracks = try XCTUnwrap(snapshot.tracksByFolder[unaffectedFolderID])
        let patchedFolderTracks = try XCTUnwrap(patched.tracksByFolder[unaffectedFolderID])
        assertSharesStorage(patchedFolderTracks, originalFolderTracks, "A history patch must not rebuild unaffected folder contents.")
        print("Patched one track in a 50,000-track catalog in \(elapsed).")
    }

    func testAlreadyCancelledPatchCannotPublishAResult() async throws {
        let snapshot = try LibrarySnapshot.build(scope: .all, tracks: [], sources: sources)
        let origins = sources
        let gate = SnapshotPatchGate()
        let task = Task.detached {
            await gate.wait()
            return try snapshot.updating(updatedTracks: [], sources: origins)
        }
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("A cancelled patch must not publish a snapshot.") }
        catch is CancellationError { }
    }

    private func assertSharesStorage<Element>(_ actual: [Element], _ expected: [Element], _ message: String,
                                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(expected.isEmpty, "Storage identity requires a nonempty prepared array.", file: file, line: line)
        XCTAssertEqual(actual.count, expected.count, message, file: file, line: line)
        expected.withUnsafeBufferPointer { expectedBuffer in
            actual.withUnsafeBufferPointer { actualBuffer in
                XCTAssertEqual(actualBuffer.baseAddress, expectedBuffer.baseAddress, message, file: file, line: line)
            }
        }
    }

    private var sources: [SourceRecord] {
        [SourceRecord(id: "first", kind: .openSubsonic, name: "First", location: "https://first.invalid"),
         SourceRecord(id: "second", kind: .openSubsonic, name: "Second", location: "https://second.invalid"),
         SourceRecord(id: "radio", kind: .radio, name: "Internet Radio", location: "radio://stations")]
    }
}

private actor SnapshotPatchGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { if !opened { await withCheckedContinuation { waiter = $0 } } }
    func open() { opened = true; waiter?.resume(); waiter = nil }
}
