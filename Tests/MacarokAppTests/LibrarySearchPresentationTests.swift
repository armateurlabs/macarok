import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

@MainActor
final class LibrarySearchPresentationTests: XCTestCase {
    func testSearchGroupsMatchingTracksForEveryLibraryPresentation() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model
        await model.start()

        model.search = "signal"
        try await expectEventually { !model.isSearching && model.displayedTracks.count == 2 }

        XCTAssertEqual(Set(model.displayedTracks.map(\.id)), ["a-signal", "a-orbit"])
        XCTAssertEqual(model.artists.map(\.name), ["Meridian Atlas"])
        XCTAssertEqual(Set(model.artists.flatMap(\.albums).map(\.id)), ["a-afterlight", "a-orbit"])
        XCTAssertEqual(Set(model.visibleAlbums.map(\.id)), ["a-afterlight", "a-orbit"])
        XCTAssertEqual(model.visibleAlbums.first { $0.id == "a-afterlight" }?.tracks.map(\.id), ["a-signal"])
        let matchingAlbum = try XCTUnwrap(model.visibleAlbums.first { $0.id == "a-afterlight" })
        XCTAssertEqual(model.tracksForAlbum(matchingAlbum).map(\.id), ["a-signal", "a-static"],
                       "Album playback must resolve the complete album from a partial search result.")
        XCTAssertEqual(Set(model.albumsForArtist("Meridian Atlas").flatMap(\.tracks).map(\.id)),
                       ["a-signal", "a-static", "a-orbit"])
        XCTAssertEqual(model.yearGroups.compactMap(\.year), [2013, 2005])
        XCTAssertEqual(Set(model.yearGroups.flatMap(\.albums).map(\.id)), ["a-afterlight", "a-orbit"])
        XCTAssertEqual(Set(model.genreGroups.map(\.title)), ["Rock", "Ambient"])
        XCTAssertEqual(Set(model.formatGroups.map(\.title)), ["FLAC", "Opus"])
        XCTAssertEqual(Set(model.genreGroups.flatMap(\.tracks).map(\.id)), ["a-signal", "a-orbit"])
        XCTAssertEqual(Set(model.formatGroups.flatMap(\.tracks).map(\.id)), ["a-signal", "a-orbit"])
        XCTAssertEqual(Set(model.folderNodes.first?.children?.map(\.id) ?? []), ["Electronic", "Rock"])
        XCTAssertEqual(model.cachedTracksInFolder("Rock").map(\.id), ["a-signal"])
        XCTAssertTrue(model.cachedTracksInFolder("Jazz").isEmpty)
        XCTAssertEqual(Set(model.cachedTracksInFolder("").map(\.id)), ["a-signal", "a-orbit"])
    }

    func testSortArrowReversesTheCurrentListAndSearchWithoutChangingThePlaylist() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model
        await model.start()
        model.add(model.tracks)
        let queue = model.queue
        model.selectLibraryView(.albums)
        let ascending = model.visibleAlbums.map(\.id)
        let artists = model.artists.map(\.id)
        XCTAssertFalse(model.librarySortIsDescending)

        model.toggleLibrarySort()
        try await expectEventually { model.visibleAlbums.map(\.id) == ascending.reversed() }
        XCTAssertTrue(model.librarySortIsDescending)
        XCTAssertEqual(model.artists.map(\.id), artists, "Each list keeps its own direction.")
        XCTAssertEqual(model.queue, queue)
        XCTAssertTrue(model.settings.librarySortOrder.isDescending(.albums))

        model.search = "signal"
        try await expectEventually { !model.isSearching && model.displayedTracks.count == 2 }
        XCTAssertEqual(model.visibleAlbums.map(\.title), ["Orbit", "Afterlight"])
        model.toggleLibrarySort()
        try await expectEventually { !model.isSearching && model.visibleAlbums.map(\.title) == ["Afterlight", "Orbit"] }
        model.search = ""
        try await expectEventually { model.visibleAlbums.map(\.id) == ascending }
        model.reloadLibrary(); await model.waitForLibraryLoad()
        XCTAssertEqual(model.visibleAlbums.map(\.id), ascending)
        XCTAssertEqual(model.queue, queue)
    }

    func testSwitchingTabsPreservesQueryAndClearingRestoresCatalogWithoutFilteringHomeHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model
        await model.start()
        let recentlyAdded = model.recentlyAdded.map(\.id)
        let recentlyPlayed = model.recentlyPlayed.map(\.id)
        let mostPlayedTracks = model.mostPlayedTracks.map(\.id)
        let mostPlayedAlbums = model.mostPlayedAlbums.map(\.id)
        let mostPlayedArtists = model.mostPlayedArtists.map(\.id)

        model.search = "signal"
        try await expectEventually { !model.isSearching && model.displayedTracks.count == 2 }
        for view in LibraryView.allCases {
            model.libraryView = view
            XCTAssertEqual(model.search, "signal", "Changing to \(view) must preserve the query.")
            XCTAssertEqual(Set(model.visibleAlbums.map(\.id)), ["a-afterlight", "a-orbit"])
            XCTAssertEqual(model.artists.map(\.name), ["Meridian Atlas"])
        }
        XCTAssertEqual(model.albums.count, 3, "The complete source catalog remains available to context views.")
        XCTAssertEqual(model.recentlyAdded.map(\.id), recentlyAdded)
        XCTAssertEqual(model.recentlyPlayed.map(\.id), recentlyPlayed)
        XCTAssertEqual(model.mostPlayedTracks.map(\.id), mostPlayedTracks)
        XCTAssertEqual(model.mostPlayedAlbums.map(\.id), mostPlayedAlbums)
        XCTAssertEqual(model.mostPlayedArtists.map(\.id), mostPlayedArtists)

        model.search = ""

        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.displayedTracks.count, 4)
        XCTAssertEqual(model.visibleAlbums.count, 3)
        XCTAssertEqual(Set(model.artists.map(\.name)), ["Meridian Atlas", "Paper Satellites"])
        XCTAssertEqual(model.yearGroups.compactMap(\.year), [2013, 2005, 1999])
        XCTAssertEqual(Set(model.genreGroups.map(\.title)), ["Rock", "Ambient", "Jazz"])
        XCTAssertEqual(Set(model.formatGroups.map(\.title)), ["FLAC", "Opus", "MP3"])
        XCTAssertEqual(Set(model.folderNodes.first?.children?.map(\.id) ?? []), ["Electronic", "Rock", "Jazz"])
        XCTAssertEqual(model.cachedTracksInFolder("Rock").count, 2)
        XCTAssertEqual(model.recentlyAdded.count, 3)
        XCTAssertEqual(model.recentlyPlayed.count, 4)
        XCTAssertEqual(model.mostPlayedTracks.count, 4)
        XCTAssertEqual(model.mostPlayedAlbums.count, 3)
        XCTAssertEqual(model.mostPlayedArtists.count, 2)
    }

    func testSearchGroupsStayWithinSelectedSourceAndEmptyResultsHaveNoGroups() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let model = fixture.model
        await model.start()
        model.search = "signal"
        try await expectEventually { !model.isSearching && model.displayedTracks.count == 2 }

        model.sourceID = fixture.secondSource.id
        XCTAssertEqual(model.search, "")
        await model.waitForLibraryLoad()
        XCTAssertEqual(model.snapshotSourceID, fixture.secondSource.id)
        model.search = "signal"
        try await expectEventually { !model.isSearching && model.displayedTracks.map(\.id) == ["b-signal"] }

        XCTAssertEqual(model.artists.map(\.name), ["Remote Artist"])
        XCTAssertEqual(model.visibleAlbums.map(\.id), ["b-cloud"])
        XCTAssertEqual(model.yearGroups.compactMap(\.year), [2024])
        XCTAssertEqual(model.genreGroups.map(\.title), ["Classical"])
        XCTAssertEqual(model.formatGroups.map(\.title), ["Ogg"])
        XCTAssertEqual(model.folderNodes.first?.children?.map(\.id), ["Cloud"])
        XCTAssertEqual(model.cachedTracksInFolder("").map(\.id), ["b-signal"])

        model.search = "nomatchingmusic"
        try await expectEventually { !model.isSearching }

        XCTAssertTrue(model.displayedTracks.isEmpty)
        XCTAssertTrue(model.artists.isEmpty)
        XCTAssertTrue(model.visibleAlbums.isEmpty)
        XCTAssertTrue(model.yearGroups.isEmpty)
        XCTAssertTrue(model.genreGroups.isEmpty)
        XCTAssertTrue(model.formatGroups.isEmpty)
        XCTAssertNil(model.folderNodes.first?.children)
        XCTAssertTrue(model.cachedTracksInFolder("").isEmpty)
        XCTAssertEqual(model.albums.map(\.id), ["b-cloud"])
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try LibraryStore(url: directory.appendingPathComponent("test.sqlite"))
        let first = SourceRecord(kind: .openSubsonic, name: "First Library", location: "https://first.invalid",
                                 createdAt: Date(timeIntervalSince1970: 1))
        let second = SourceRecord(kind: .openSubsonic, name: "Second Library", location: "https://second.invalid",
                                  createdAt: Date(timeIntervalSince1970: 2))
        try store.saveSource(first)
        try store.saveSource(second)
        let played = Date(timeIntervalSince1970: 100)
        try store.upsertTracks([
            TrackRecord(id: "a-signal", sourceID: first.id, albumID: "a-afterlight", title: "Signal Fire",
                        artist: "Meridian Atlas", album: "Afterlight", year: 2005, genre: "Rock", trackNumber: 1,
                        remotePath: "Rock/Live/01.flac", format: "FLAC", lastPlayedAt: played, playCount: 2),
            TrackRecord(id: "a-static", sourceID: first.id, albumID: "a-afterlight", title: "Static Bloom",
                        artist: "Meridian Atlas", album: "Afterlight", year: 2005, genre: "Rock", trackNumber: 2,
                        remotePath: "Rock/Live/02.flac", format: "FLAC", lastPlayedAt: played, playCount: 1),
            TrackRecord(id: "a-orbit", sourceID: first.id, albumID: "a-orbit", title: "Night Signal",
                        artist: "Meridian Atlas", album: "Orbit", year: 2013, genre: "Ambient", trackNumber: 1,
                        remotePath: "Electronic/Orbit/01.opus", format: "Opus", lastPlayedAt: played, playCount: 3),
            TrackRecord(id: "a-paper", sourceID: first.id, albumID: "a-field", title: "Paper Boat",
                        artist: "Paper Satellites", album: "Field Notes", year: 1999, genre: "Jazz", trackNumber: 1,
                        remotePath: "Jazz/Field/01.mp3", format: "MP3", lastPlayedAt: played, playCount: 4),
            TrackRecord(id: "b-signal", sourceID: second.id, albumID: "b-cloud", title: "Remote Signal",
                        artist: "Remote Artist", album: "Cloud Album", year: 2024, genre: "Classical", trackNumber: 1,
                        remotePath: "Cloud/Album/01.ogg", format: "Ogg", lastPlayedAt: played, playCount: 1)
        ])
        let model = AppModel(store: store, preferences: AppPreferences(), registerSystemControls: false)
        return Fixture(directory: directory, model: model, secondSource: second)
    }

    private func expectEventually(file: StaticString = #filePath, line: UInt = #line,
                                  _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for search presentation.", file: file, line: line)
        throw WaitError.timedOut
    }

    private enum WaitError: Error { case timedOut }

    private struct Fixture {
        let directory: URL
        let model: AppModel
        let secondSource: SourceRecord
        func removeFiles() { try? FileManager.default.removeItem(at: directory) }
    }
}
