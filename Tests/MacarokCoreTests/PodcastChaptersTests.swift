import Foundation
import XCTest
@testable import MacarokCore

final class PodcastChaptersTests: XCTestCase {
    func testNormalizationSortsDeduplicatesClampsAndOpensAtZero() {
        let chapters = PodcastChapters.normalized([
            PodcastChapter(start: 300, title: " Two "), PodcastChapter(start: 60, title: "One"),
            PodcastChapter(start: 60, title: "Duplicate"), PodcastChapter(start: 4_000, title: "After the end"),
            PodcastChapter(start: -1, title: "Negative"),
        ], duration: 3_600)
        XCTAssertEqual(chapters.map(\.start), [0, 60, 300])
        XCTAssertEqual(chapters.map(\.title), ["", "One", "Two"])
        XCTAssertTrue(PodcastChapters.normalized([PodcastChapter(start: 0, title: "Only")]).isEmpty)
    }

    func testJSONChaptersSkipHiddenEntriesAndUnsafeLinks() throws {
        let json = #"""
        {"version":"1.2.0","chapters":[{"startTime":0,"title":"Intro"},{"startTime":92.5,"title":"Interview","url":"https://example.org/guest"},
        {"startTime":120,"title":"Ad","toc":false},{"startTime":1800,"title":"End","url":"javascript:alert(1)"},{"title":"No time"}]}
        """#
        let chapters = try PodcastChapters.parseJSON(Data(json.utf8))
        XCTAssertEqual(chapters.map(\.start), [0, 92.5, 1800])
        XCTAssertEqual(chapters[1].url?.absoluteString, "https://example.org/guest")
        XCTAssertNil(chapters[2].url)
    }

    func testNotesChaptersRequireAnOrderedListAtLineStarts() {
        let notes = """
        Dans cet épisode, rendez-vous à 14:30 pour le direct.
        CHAPITRES :
        ▪️ 00:00 Introduction
        ▪️ 01:05 Les premiers signes – d’un vieillissement accéléré
        • 05:41 Le biomarqueur sanguin
        (1:02:03) Conclusion
        Voir https://example.org/?t=12:34
        """
        let chapters = PodcastChapters.fromNotes(notes, duration: 7_200)
        XCTAssertEqual(chapters.map(\.start), [0, 65, 341, 3_723])
        XCTAssertEqual(chapters.map(\.title), ["Introduction", "Les premiers signes – d’un vieillissement accéléré", "Le biomarqueur sanguin", "Conclusion"])
        XCTAssertTrue(PodcastChapters.fromNotes("00:00 A\n05:00 B", duration: 600).isEmpty, "Two lines are not a list.")
        XCTAssertTrue(PodcastChapters.fromNotes("00:00 A\n05:00 B\n03:00 C", duration: 600).isEmpty, "Times must increase.")
        XCTAssertTrue(PodcastChapters.fromNotes("10:00 A\n15:00 B\n20:00 C", duration: 3_600).isEmpty, "A list starts near the beginning.")
        XCTAssertTrue(PodcastChapters.fromNotes("00:00 A\n05:00 B\n59:00 C", duration: 1_800).isEmpty, "Times stay inside the episode.")
        XCTAssertEqual(PodcastChapters.time("01:02:03.500"), 3_723.5)
        XCTAssertEqual(PodcastChapters.time("90.25"), 90.25)
        XCTAssertNil(PodcastChapters.time("1:x"))
    }

    func testFeedChaptersAreParsedStoredAndRemovedWithTheirSource() throws {
        let xml = """
        <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0" xmlns:psc="http://podlove.org/simple-chapters"><channel><title>Show</title>
        <item><guid>json</guid><title>A</title><enclosure url="https://audio.example/a.mp3" type="audio/mpeg"/>
        <podcast:chapters url="https://show.example/a.json" type="application/json+chapters"/></item>
        <item><guid>psc</guid><title>B</title><enclosure url="https://audio.example/b.mp3" type="audio/mpeg"/>
        <psc:chapters version="1.2"><psc:chapter start="00:00:00.000" title="Start"/><psc:chapter start="00:12:30" title="Middle &amp; more" href="https://show.example/m"/></psc:chapters></item>
        </channel></rss>
        """
        let feed = try PodcastClient.parse(data: Data(xml.utf8), sourceURL: URL(string: "https://show.example/feed.xml")!)
        XCTAssertEqual(feed.episodes[0].chaptersURL?.absoluteString, "https://show.example/a.json")
        XCTAssertEqual(feed.episodes[1].chapters, [PodcastChapter(start: 0, title: "Start"),
                                                  PodcastChapter(start: 750, title: "Middle & more", url: URL(string: "https://show.example/m"))])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokChapters-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let source = SourceRecord(id: "show", kind: .podcasts, name: "Show", location: feed.url.absoluteString)
        let tracks = feed.episodes.map { $0.asTrackRecord(sourceID: source.id, feed: feed) }
        try store.saveSource(source, tracks: tracks)
        try store.savePodcastFeed(sourceID: source.id, feed: feed, validators: PodcastFeedValidators())
        XCTAssertEqual(try store.podcastChapterSources(trackID: tracks[0].id).url, feed.episodes[0].chaptersURL)
        XCTAssertEqual(try store.podcastChapterSources(trackID: tracks[1].id).chapters, feed.episodes[1].chapters)
        try store.savePodcastChapters(Data("{}".utf8), trackID: tracks[0].id, sourceID: source.id)
        XCTAssertEqual(try store.cachedPodcastChapters(trackID: tracks[0].id), Data("{}".utf8))
        try store.deleteSource(id: source.id)
        XCTAssertNil(try store.cachedPodcastChapters(trackID: tracks[0].id))
    }
}
