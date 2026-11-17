import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

final class PodcastLibraryOrderTests: XCTestCase {
    func testEveryPreparedFeedGroupUsesPublicationDateDescendingWithUnknownDatesLast() throws {
        let source = podcastSource("podcast")
        let newest = episode("new", source: source, date: 1_800_000_000, number: 1, season: 1)
        let oldest = episode("old", source: source, date: 1_600_000_000, number: 999, season: 9)
        let tieA = episode("tie-a", source: source, date: 1_700_000_000, title: "Same")
        let tieB = episode("tie-b", source: source, date: 1_700_000_000, title: "Same")
        let unknown = episode("unknown", source: source, date: nil)
        let input = [oldest, tieB, unknown, newest, tieA]
        let expected = [newest.id] + [tieA.id, tieB.id].sorted() + [oldest.id, unknown.id]
        let snapshot = try LibrarySnapshot.build(sourceID: source.id, tracks: input, sources: [source])
        XCTAssertEqual(snapshot.tracks.map(\.id), expected)
        XCTAssertEqual(snapshot.albums.first?.tracks.map(\.id), expected)
        XCTAssertEqual(snapshot.artists.first?.albums.first?.tracks.map(\.id), expected)
        XCTAssertEqual(snapshot.yearGroups.first?.albums.first?.tracks.map(\.id), expected)
        XCTAssertEqual(snapshot.genreGroups.first?.tracks.map(\.id), expected)
        XCTAssertEqual(snapshot.formatGroups.first?.tracks.map(\.id), expected)
        XCTAssertEqual(snapshot.tracksByFolder[""]?.map(\.id), expected)
        XCTAssertEqual(try LibrarySnapshot.build(sourceID: source.id, tracks: Array(input.reversed()), sources: [source]).tracks.map(\.id), expected)

        var updated = oldest
        updated.rating = 4
        let patched = try snapshot.updating(updatedTracks: [updated], sources: [source])
        XCTAssertEqual(patched.tracks.map(\.id), expected)
        XCTAssertEqual(patched.albums.first?.tracks.map(\.id), expected)
    }

    func testAllSourcesKeepsPodcastsOutOfMusicListsAndKeepsIdenticalFeedCopiesIndependent() throws {
        let first = podcastSource("podcast-a"), second = podcastSource("podcast-b")
        let music = SourceRecord(id: "music", kind: .local, name: "Music", location: "file:///Music/")
        let firstOld = episode("a-old", source: first, date: 1_600_000_000, number: 1)
        let firstNew = episode("a-new", source: first, date: 1_800_000_000, number: 3)
        var secondOld = episode("b-old", source: second, date: 1_500_000_000, number: 2)
        var secondNew = episode("b-new", source: second, date: 1_900_000_000, number: 4)
        secondOld.albumID = firstOld.albumID
        secondNew.albumID = firstOld.albumID
        let musicTracks = (1...4).map { number in
            TrackRecord(id: "music-\(number)", sourceID: music.id, albumID: "music-album", title: "Episode \(number)",
                artist: "Host", albumArtist: "Host", album: "Show", genre: "Podcast", trackNumber: number,
                addedAt: Date(timeIntervalSince1970: Double(number)))
        }
        let input = [firstOld, firstNew, secondOld, secondNew] + musicTracks
        let snapshot = try LibrarySnapshot.build(scope: .all, tracks: Array(input.reversed()), sources: [first, second, music])
        XCTAssertEqual(snapshot.tracks.map(\.id), musicTracks.map(\.id), "All Sources music lists contain music only, in their own order.")
        XCTAssertEqual(snapshot.podcastEpisodes.filter { $0.sourceID == first.id }.map(\.id), [firstNew.id, firstOld.id])
        XCTAssertEqual(snapshot.podcastEpisodes.filter { $0.sourceID == second.id }.map(\.id), [secondNew.id, secondOld.id])
        XCTAssertEqual(snapshot.albumsByID[StableID.make(first.id, "album", firstOld.albumID)]?.tracks.map(\.id), [firstNew.id, firstOld.id])
        XCTAssertEqual(snapshot.albumsByID[StableID.make(second.id, "album", secondOld.albumID)]?.tracks.map(\.id), [secondNew.id, secondOld.id])
        XCTAssertEqual(snapshot.tracksByID[firstNew.id]?.id, firstNew.id, "Episodes stay addressable for selection and playback.")
        XCTAssertFalse(snapshot.albums.contains { [first.id, second.id].contains($0.sourceID) })
        XCTAssertFalse(snapshot.recentlyAdded.contains { [first.id, second.id].contains($0.sourceID) },
                       "A frequently publishing show must not occupy Recently Added.")
        XCTAssertFalse(snapshot.artists.flatMap(\.albums).contains { [first.id, second.id].contains($0.sourceID) })
        XCTAssertEqual(snapshot.folderNodes.map(\.name), [music.name])

        var played = firstNew
        played.playCount = 3
        let patched = try snapshot.updating(updatedTracks: [played], sources: [first, second, music])
        XCTAssertEqual(patched.tracks.map(\.id), musicTracks.map(\.id))
        XCTAssertEqual(patched.podcastEpisodes.first { $0.id == firstNew.id }?.playCount, 3)
        XCTAssertTrue(patched.mostPlayedTracks.isEmpty, "Podcast plays do not enter music rankings.")
    }

    @MainActor
    func testCachedFeedSearchAndCompleteAlbumActionsUseNewOrderWithoutReorderingQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokPodcastOrder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let source = podcastSource("podcast")
        let old = episode("old", source: source, date: 1_600_000_000, title: "Episode Old", number: 1)
        let new = episode("new", source: source, date: 1_800_000_000, title: "Episode New", number: 2)
        let undated = episode("undated", source: source, date: nil, title: "Undated")
        try store.saveSource(source, tracks: [old, undated, new])
        try store.saveQueue(trackIDs: [old.id, new.id, old.id], currentIndex: -1, position: 0)
        let model = AppModel(store: store, registerSystemControls: false)
        await model.start()
        let existingQueueIDs = model.queue.map(\.id)
        XCTAssertEqual(model.displayedTracks.map(\.id), [new.id, old.id, undated.id],
                       "Previously cached feeds must change order without fetching RSS again.")
        XCTAssertEqual(model.queue.map(\.track.id), [old.id, new.id, old.id])
        model.search = "Episode"
        for _ in 0..<200 {
            if !model.isSearching { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isSearching)
        let searchAlbum = try XCTUnwrap(model.visibleAlbums.first)
        XCTAssertEqual(searchAlbum.tracks.map(\.id), [new.id, old.id])
        XCTAssertEqual(model.tracksForAlbum(searchAlbum).map(\.id), [new.id, old.id, undated.id])
        model.add(model.tracksForAlbum(searchAlbum))
        XCTAssertEqual(Array(model.queue.prefix(3)).map(\.id), existingQueueIDs)
        XCTAssertEqual(model.queue.map(\.track.id), [old.id, new.id, old.id, new.id, old.id, undated.id])
        await model.finishPlaybackAccess()
    }

    private func podcastSource(_ id: String) -> SourceRecord {
        SourceRecord(id: id, kind: .podcasts, name: "Show", location: "https://example.org/\(id)/feed.xml")
    }

    private func episode(_ id: String, source: SourceRecord, date: TimeInterval?, title: String? = nil,
                         number: Int? = nil, season: Int? = nil) -> TrackRecord {
        PodcastEpisode(id: id, title: title ?? "Episode \(id)", audioURL: URL(string: "https://example.org/\(id).mp3")!,
            publicationDate: date.map { Date(timeIntervalSince1970: $0) }, episodeNumber: number, seasonNumber: season)
            .asTrackRecord(sourceID: source.id, feed: PodcastFeed(url: source.url!, title: "Show", author: "Host"))
    }
}
