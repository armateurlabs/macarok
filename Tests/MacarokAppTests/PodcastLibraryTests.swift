import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

final class PodcastLibraryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_916_800) // Tue 17 Nov 2026 12:00 UTC
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "UTC")!
        return value
    }

    func testShortDatesAreRelativeForRecentEpisodesAndRemainingTimeIsRounded() {
        func short(_ days: Double) -> String {
            PodcastDate.short(now.addingTimeInterval(-days * 86_400), now: now, calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
        }
        XCTAssertEqual(short(0), "Today")
        XCTAssertEqual(short(1), "Yesterday")
        XCTAssertEqual(short(3), "Sat")
        XCTAssertEqual(short(10), "Nov 7")
        XCTAssertEqual(short(330), "Dec 22, 2025")
        XCTAssertEqual(PodcastDate.remaining(1_380), "23 min left")
        XCTAssertEqual(PodcastDate.remaining(3_900), "1 h 5 min left")
        XCTAssertEqual(PodcastDate.remaining(5), "1 min left")
    }

    func testShowsAndEpisodeListsFollowPublicationDateAndFilters() {
        let first = podcastSource("first"), second = podcastSource("second"), empty = podcastSource("empty")
        let music = SourceRecord(id: "music", kind: .local, name: "Music", location: "file:///Music/")
        let firstOld = episode("a-old", source: first, daysAgo: 40), firstNew = episode("a-new", source: first, daysAgo: 2)
        let secondNew = episode("b-new", source: second, daysAgo: 1), undated = episode("b-undated", source: second, daysAgo: nil)
        let song = TrackRecord(id: "song", sourceID: music.id, title: "Song")
        let all = [firstOld, firstNew, secondNew, undated, song]
        let played: Set<String> = [firstNew.id]
        let state: (TrackRecord) -> PodcastEpisodeState = { played.contains($0.id) ? .played : .unplayed }

        let shows = PodcastLibrary.shows(episodes: all, sources: [music, empty, first, second], state: state)
        XCTAssertEqual(shows.map(\.id), [second.id, first.id, empty.id], "Shows order by latest episode; empty shows last.")
        XCTAssertEqual(shows.first?.latestEpisode?.id, secondNew.id)
        XCTAssertEqual(shows.map(\.unplayedCount), [2, 1, 0])
        XCTAssertEqual(PodcastLibrary.shows(episodes: all, sources: [first, second], state: state, newestFirst: false).map(\.id), [first.id, second.id])

        XCTAssertEqual(PodcastLibrary.episodes(all, showID: first.id, filter: .all, state: state, isDownloaded: { _ in false }).map(\.id),
                       [firstNew.id, firstOld.id])
        XCTAssertEqual(PodcastLibrary.episodes(all, showID: first.id, filter: .all, state: state, isDownloaded: { _ in false }, newestFirst: false).map(\.id),
                       [firstOld.id, firstNew.id])
        XCTAssertEqual(PodcastLibrary.episodes(all, showID: second.id, filter: .all, state: state, isDownloaded: { _ in false }, newestFirst: false).map(\.id),
                       [secondNew.id, undated.id], "Undated episodes stay last in both directions.")
        XCTAssertEqual(PodcastLibrary.episodes(all, showID: first.id, filter: .unplayed, state: state, isDownloaded: { _ in false }).map(\.id), [firstOld.id])
        XCTAssertEqual(PodcastLibrary.episodes(all, filter: .downloaded, state: state, isDownloaded: { $0.id == undated.id }).map(\.id), [undated.id])

        let episodes = all.filter { $0.sourceID != music.id }
        XCTAssertEqual(PodcastLibrary.newEpisodes(episodes, state: state, now: now).map(\.id), [secondNew.id],
                       "New lists recent unplayed episodes; old, played, and undated episodes are excluded.")
        XCTAssertEqual(PodcastLibrary.latestUnplayedPerShow(episodes, state: state).map(\.id), [secondNew.id, firstOld.id])

        let updated = [firstOld.id: now, undated.id: now.addingTimeInterval(-60)]
        let progressing: (TrackRecord) -> PodcastEpisodeState = { updated[$0.id] == nil ? .unplayed : .inProgress(position: 60, remaining: 60) }
        XCTAssertEqual(PodcastLibrary.inProgress(episodes, state: progressing, updatedAt: { updated[$0.id] }).map(\.id), [firstOld.id, undated.id])
    }

    func testNotesLinkWebAddressesAndChapterTimes() {
        let notes = "00:00 Intro\n01:05 Signes\n1:02:03 Fin\nVoir https://example.org/p?t=12:34 ou 2026, 14h30.\nmailto:contact@example.org"
        let text = PodcastNotesFormatter.attributed(notes)
        let links = text.runs.compactMap { run in run.link.map { (String(text[run.range].characters), $0) } }
        XCTAssertEqual(links.map(\.0), ["00:00", "01:05", "1:02:03", "https://example.org/p?t=12:34", "mailto:contact@example.org"])
        XCTAssertEqual(links.compactMap { PodcastNotesFormatter.seconds(from: $0.1) }, [0, 65, 3723])
        XCTAssertNil(PodcastNotesFormatter.seconds(from: URL(string: "https://example.org/12")!))
    }

    func testChaptersPreferPublisherDataAndNavigateLikeTracks() {
        let json = [PodcastChapter(start: 0, title: "J1"), PodcastChapter(start: 100, title: "J2")]
        let feed = [PodcastChapter(start: 0, title: "F1"), PodcastChapter(start: 200, title: "F2")]
        let notes = "00:00 N1\n01:00 N2\n02:00 N3"
        XCTAssertEqual(PodcastController.resolveChapters(json: json, feed: feed, notes: notes, duration: 600).map(\.title), ["J1", "J2"])
        XCTAssertEqual(PodcastController.resolveChapters(json: [], feed: feed, notes: notes, duration: 600).map(\.title), ["F1", "F2"])
        XCTAssertEqual(PodcastController.resolveChapters(json: [], feed: [], notes: notes, duration: 600).map(\.title), ["N1", "N2", "N3"])

        let chapters = [PodcastChapter(start: 0, title: "A"), PodcastChapter(start: 60, title: "B"), PodcastChapter(start: 120, title: "C")]
        XCTAssertEqual(PodcastController.chapterIndex(chapters, at: 59.9), 1, "A seek landing just before a boundary counts as that chapter.")
        XCTAssertEqual(PodcastController.chapterIndex(chapters, at: 90), 1)
        XCTAssertEqual(PodcastController.nextChapterTarget(chapters, position: 90), 120)
        XCTAssertNil(PodcastController.nextChapterTarget(chapters, position: 130))
        XCTAssertEqual(PodcastController.previousChapterTarget(chapters, position: 90), 60, "Past three seconds, restart the chapter.")
        XCTAssertEqual(PodcastController.previousChapterTarget(chapters, position: 61), 0, "At its start, go to the previous chapter.")
        XCTAssertEqual(PodcastController.previousChapterTarget(chapters, position: 1), 0)

        XCTAssertTrue(PlaybackArrowKeys.isChapterKey(keyCode: 124, modifiers: [.option, .numericPad, .function]))
        XCTAssertFalse(PlaybackArrowKeys.isChapterKey(keyCode: 124, modifiers: [.option, .shift]))
        XCTAssertFalse(PlaybackArrowKeys.isChapterKey(keyCode: 124, modifiers: []))
        XCTAssertFalse(PlaybackArrowKeys.isReserved(keyCode: 124, modifiers: .option), "Option arrows never fall back to a five-second seek.")
    }

    @MainActor
    func testEpisodeChaptersLoadFromTheFeedAndTheCachedJSONWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokChapterLoad-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let source = podcastSource("show")
        let feed = PodcastFeed(url: source.url!, title: "Show", episodes: [
            PodcastEpisode(id: "psc", title: "Podlove", audioURL: URL(string: "https://example.org/a.mp3")!, duration: 600,
                           chapters: [PodcastChapter(start: 0, title: "Start"), PodcastChapter(start: 300, title: "Half")]),
            PodcastEpisode(id: "json", title: "JSON", audioURL: URL(string: "https://example.org/b.mp3")!, duration: 600,
                           chaptersURL: URL(string: "https://chapters.invalid/b.json")),
            PodcastEpisode(id: "notes", title: "Notes", description: "00:00 Intro\n02:00 Topic\n04:00 Outro",
                           audioURL: URL(string: "https://example.org/c.mp3")!, duration: 600),
        ])
        let tracks = feed.episodes.map { $0.asTrackRecord(sourceID: source.id, feed: feed) }
        try store.saveSource(source, tracks: tracks)
        try store.savePodcastFeed(sourceID: source.id, feed: feed, validators: PodcastFeedValidators())
        try store.savePodcastChapters(Data(#"{"version":"1.2.0","chapters":[{"startTime":0,"title":"Cold open"},{"startTime":42,"title":"Guest"}]}"#.utf8),
                                      trackID: tracks[1].id, sourceID: source.id)
        var preferences = AppPreferences()
        preferences.volume = 0
        let model = AppModel(store: store, preferences: preferences, registerSystemControls: false)
        await model.start()
        let podlove = await model.podcasts.chapters(for: tracks[0])
        let cached = await model.podcasts.chapters(for: tracks[1])
        let fromNotes = await model.podcasts.chapters(for: tracks[2])
        XCTAssertEqual(podlove.map(\.title), ["Start", "Half"])
        XCTAssertEqual(cached.map(\.title), ["Cold open", "Guest"])
        XCTAssertEqual(fromNotes.map(\.start), [0, 120, 240])
        XCTAssertFalse(model.canSeekChapters, "Nothing is playing.")
    }

    func testEpisodeStateUsesSavedProgressBeforeLibraryHistory() {
        let source = podcastSource("show")
        var track = episode("e", source: source, daysAgo: 1)
        track.duration = 900
        XCTAssertEqual(PodcastController.state(progress: nil, track: track), .unplayed)
        var heard = track
        heard.lastPlayedAt = now
        XCTAssertEqual(PodcastController.state(progress: nil, track: heard), .played, "Episodes heard before progress existed count as played.")
        func progress(_ position: Double, duration: Double = 600, finished: Bool = false) -> PodcastProgressRecord {
            PodcastProgressRecord(trackID: track.id, sourceID: source.id, position: position, duration: duration, isFinished: finished)
        }
        XCTAssertEqual(PodcastController.state(progress: progress(10), track: heard), .unplayed, "A short preview or explicit reset is unplayed.")
        XCTAssertEqual(PodcastController.state(progress: progress(120), track: track), .inProgress(position: 120, remaining: 480))
        XCTAssertEqual(PodcastController.state(progress: progress(120, duration: 0), track: track), .inProgress(position: 120, remaining: 780))
        XCTAssertEqual(PodcastController.state(progress: progress(590, finished: true), track: track), .played)
    }

    func testAutomaticRefreshSelectsOnlyStalePodcastShows() {
        let fresh = podcastSource("fresh"), stale = podcastSource("stale"), unknown = podcastSource("unknown"), failed = podcastSource("failed")
        let music = SourceRecord(id: "music", kind: .local, name: "Music", location: "file:///Music/")
        let shows = [fresh.id: PodcastShowRecord(sourceID: fresh.id, title: "Fresh", refreshedAt: now.addingTimeInterval(-600)),
                     stale.id: PodcastShowRecord(sourceID: stale.id, title: "Stale", refreshedAt: now.addingTimeInterval(-4_000))]
        let sources = [fresh, stale, unknown, failed, music]
        let attempts = [failed.id: now.addingTimeInterval(-60)]
        XCTAssertEqual(PodcastController.due(sources: sources, shows: shows, attempts: attempts, interval: 3_600, now: now), [stale.id, unknown.id])
        XCTAssertEqual(PodcastController.due(sources: sources, shows: shows, attempts: attempts, interval: 0, now: now), [])
    }

    func testPodcastSortDefaultsToNewestFirstForExistingPreferences() throws {
        var order = try JSONDecoder().decode(LibrarySortOrder.self, from: Data(#"["years"]"#.utf8))
        XCTAssertTrue(order.isDescending(.podcasts))
        XCTAssertTrue(order.isDescending(.years))
        order.toggle(.podcasts)
        XCTAssertFalse(order.isDescending(.podcasts))
        XCTAssertFalse(try JSONDecoder().decode(LibrarySortOrder.self, from: JSONEncoder().encode(order)).isDescending(.podcasts))

        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8)).podcastRefreshInterval, 3_600)
        var preferences = AppPreferences()
        preferences.podcastRefreshInterval = 0
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences)).podcastRefreshInterval, 0)
    }

    @MainActor
    func testPodcastsTabOpensShowsAndTracksListeningState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokPodcastLibrary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let show = podcastSource("show")
        let music = SourceRecord(id: "music", kind: .local, name: "Music", location: root.path)
        let old = episode("old", source: show, daysAgo: 20), new = episode("new", source: show, daysAgo: 1)
        try store.saveSource(show, tracks: [old, new])
        try store.saveSource(music, tracks: [TrackRecord(id: "song", sourceID: music.id, albumID: "album", title: "Song", artist: "Artist", album: "Album")])
        var preferences = AppPreferences()
        preferences.volume = 0
        let model = AppModel(store: store, preferences: preferences, registerSystemControls: false)
        await model.start()
        model.libraryScope = .all
        await model.waitForLibraryLoad()

        XCTAssertEqual(model.tracks.map(\.id), ["song"], "All Sources music views exclude podcasts.")
        XCTAssertEqual(model.allPodcastEpisodes.map(\.id), [new.id, old.id])
        XCTAssertEqual(model.visibleLibraryViews.last, .podcasts)
        XCTAssertTrue(model.showsPodcastHome)

        model.openPodcastShow(show.id)
        XCTAssertEqual(model.libraryView, .podcasts)
        XCTAssertEqual(model.focusedPodcastShowID, show.id)
        XCTAssertEqual(model.centerPage, .home)
        XCTAssertEqual(model.podcastEpisodes(showID: show.id, filter: .all).map(\.id), [new.id, old.id])
        model.toggleLibrarySort()
        XCTAssertEqual(model.podcastEpisodes(showID: show.id, filter: .all).map(\.id), [old.id, new.id])
        XCTAssertFalse(model.settings.librarySortOrder.isDescending(.podcasts))
        XCTAssertTrue(model.settings.librarySortOrder.isDescending(.years), "Only the podcast direction changes.")
        model.toggleLibrarySort()

        model.podcasts.record(track: old, position: 120, duration: 600)
        XCTAssertEqual(model.podcasts.state(old), .inProgress(position: 120, remaining: 480))
        XCTAssertEqual(model.podcasts.resumePosition(for: old), 118)
        XCTAssertEqual(model.inProgressPodcastEpisodes().map(\.id), [old.id])
        XCTAssertEqual(model.podcastEpisodes(showID: show.id, filter: .unplayed).map(\.id), [new.id])
        XCTAssertEqual(model.playbackStartPosition(for: QueueItem(track: old)), 118, "Playing an in-progress episode resumes it.")
        XCTAssertEqual(model.playbackStartPosition(for: QueueItem(track: new)), 0)
        XCTAssertEqual(model.playbackStartPosition(for: QueueItem(track: model.tracks[0])), 0, "Music always starts at its beginning.")
        model.podcasts.record(track: old, position: 580, duration: 600)
        XCTAssertEqual(model.podcasts.state(old), .played, "The final seconds count as finished.")
        XCTAssertNil(model.podcasts.resumePosition(for: old))

        model.podcasts.setPlayed(true, tracks: model.showEpisodes(show.id))
        XCTAssertTrue(model.newPodcastEpisodes(now: now).isEmpty)
        XCTAssertEqual(model.podcastShowSummaries.first?.unplayedCount, 0)
        model.podcasts.setPlayed(false, tracks: [new])
        XCTAssertEqual(model.newPodcastEpisodes(now: now).map(\.id), [new.id])

        model.centerPage = .playing
        model.inspect(new)
        model.contextMode = .lyrics
        XCTAssertEqual(model.displayedContextMode, .context, "Episodes always show their context in Playing.")
        model.beginMetadataEditing(new)
        XCTAssertNil(model.metadataEditingSession, "Episodes have no editable tags.")
        model.inspect(model.tracks[0])
        XCTAssertEqual(model.displayedContextMode, .lyrics, "The chosen view returns for music.")
        model.contextMode = .context

        model.libraryScope = .source(music.id)
        XCTAssertNil(model.podcasts.openShowID)
        XCTAssertEqual(model.libraryView, .home, "A scope without podcasts leaves the hidden Podcasts tab.")
        XCTAssertFalse(model.visibleLibraryViews.contains(.podcasts))

        for _ in 0..<100 where (try? store.podcastProgress().count) != 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try store.podcastProgress()[new.id]?.isFinished, false, "Listening state persists.")
        XCTAssertEqual(try store.podcastProgress()[old.id]?.isFinished, true)
    }

    private func podcastSource(_ id: String) -> SourceRecord {
        SourceRecord(id: id, kind: .podcasts, name: id.capitalized, location: "https://example.org/\(id)/feed.xml")
    }

    private func episode(_ id: String, source: SourceRecord, daysAgo: Double?) -> TrackRecord {
        PodcastEpisode(id: id, title: "Episode \(id)", audioURL: URL(string: "https://example.org/\(id).mp3")!,
                       publicationDate: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) }, duration: 600)
            .asTrackRecord(sourceID: source.id, feed: PodcastFeed(url: source.url!, title: source.name, author: "Host"))
    }
}
