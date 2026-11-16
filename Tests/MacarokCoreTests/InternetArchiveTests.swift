import Foundation
import XCTest
@testable import MacarokCore

final class InternetArchiveTests: XCTestCase {
    private let showJSON = """
    {"metadata": {"identifier": "gd1977-05-08.flac16", "title": "Grateful Dead Live at Barton Hall on 1977-05-08",
      "creator": ["Grateful Dead"], "date": "1977-05-08", "venue": "Barton Hall", "coverage": "Ithaca, NY",
      "source": "Soundboard", "description": ["Set 1<br>Minglewood", "&amp; more"], "collection": ["GratefulDead", "etree"]},
     "files": [
      {"name": "gd77s1t02.flac", "format": "Flac", "source": "original", "title": "Loser", "track": "02", "length": "470.2"},
      {"name": "gd77s1t02.mp3", "format": "VBR MP3", "source": "derivative", "original": "gd77s1t02.flac", "length": "07:50"},
      {"name": "gd77s1t01.flac", "format": "Flac", "source": "original", "title": "Minglewood Blues", "track": "01", "length": "322.89", "private": "true"},
      {"name": "gd77s1t01.mp3", "format": "VBR MP3", "source": "derivative", "original": "gd77s1t01.flac", "title": "Minglewood Blues", "length": "05:22"},
      {"name": "gd77s1t01.ogg", "format": "Ogg Vorbis", "source": "derivative", "original": "gd77s1t01.flac"},
      {"name": "video.mp4", "format": "MPEG4", "source": "original"},
      {"name": "video.mp3", "format": "VBR MP3", "source": "derivative", "original": "video.mp4"},
      {"name": "info.txt", "format": "Text", "source": "original"}
     ]}
    """

    private let bookJSON = """
    {"metadata": {"identifier": "wind_librivox", "title": "The Untempered Wind", "creator": "Joanna E. Wood", "date": "2021-02-23", "language": "eng"},
     "files": [
      {"name": "wind_01_128kb.mp3", "format": "128Kbps MP3", "source": "original", "title": "01 - Chapter 1", "track": "1", "length": "644.6"},
      {"name": "wind_01_64kb.mp3", "format": "64Kbps MP3", "source": "derivative", "original": "wind_01_128kb.mp3"},
      {"name": "wind_01.mp3", "format": "VBR MP3", "source": "derivative", "original": "wind_01_128kb.mp3"},
      {"name": "Wind_librivox.m4b", "format": "Audiobook", "source": "original"}
     ]}
    """

    func testLiveShowPrefersPublicLosslessAndKeepsStableTrackIdentity() throws {
        let item = try InternetArchiveClient.parseItem(data: Data(showJSON.utf8), identifier: "gd1977-05-08.flac16")
        XCTAssertEqual(item.creator, "Grateful Dead")
        XCTAssertEqual(item.description, "Set 1\nMinglewood\n& more")
        XCTAssertEqual(item.albumTitle(for: .liveMusic), "1977-05-08 Barton Hall, Ithaca, NY")

        let high = item.trackRecords(sourceID: "s", collection: .liveMusic, quality: .high)
        // The private FLAC falls back to its MP3 derivative; audio derived from video is ignored.
        XCTAssertEqual(high.map(\.title), ["Minglewood Blues", "Loser"])
        XCTAssertEqual(high.map(\.format), ["MP3", "FLAC"])
        XCTAssertEqual(high.map(\.duration), [322.89, 470.2])
        XCTAssertEqual(high.map(\.year), [1977, 1977])
        XCTAssertEqual(high[1].fileURL, "https://archive.org/download/gd1977-05-08.flac16/gd77s1t02.flac")
        XCTAssertEqual(Set(high.map(\.albumID)).count, 1)

        let standard = item.trackRecords(sourceID: "s", collection: .liveMusic, quality: .standard)
        XCTAssertEqual(standard.map(\.format), ["MP3", "MP3"])
        XCTAssertEqual(standard.map(\.id), high.map(\.id))
    }

    func testLibriVoxQualityChoosesBitrateAndIgnoresM4B() throws {
        let item = try InternetArchiveClient.parseItem(data: Data(bookJSON.utf8), identifier: "wind_librivox")
        let high = item.trackRecords(sourceID: "s", collection: .librivox, quality: .high)
        let standard = item.trackRecords(sourceID: "s", collection: .librivox, quality: .standard)
        XCTAssertEqual(high.map(\.fileURL), ["https://archive.org/download/wind_librivox/wind_01_128kb.mp3"])
        XCTAssertEqual(standard.map(\.fileURL), ["https://archive.org/download/wind_librivox/wind_01_64kb.mp3"])
        XCTAssertEqual(high.first?.genre, "Audiobook")
        XCTAssertNil(high.first?.year)
        XCTAssertEqual(item.albumTitle(for: .librivox), "The Untempered Wind")
    }

    func testUnavailableItemAndEncodedDownloadPath() {
        XCTAssertThrowsError(try InternetArchiveClient.parseItem(data: Data("{}".utf8), identifier: "missing")) {
            XCTAssertEqual($0 as? ArchiveError, .itemUnavailable("missing"))
        }
        XCTAssertEqual(InternetArchiveClient.downloadURL(identifier: "show", file: "Disc 1/01 Song #1?.flac").absoluteString,
                       "https://archive.org/download/show/Disc%201/01%20Song%20%231%3F.flac")
    }

    func testSearchQueriesEscapeUserTextAndApplyFilters() throws {
        func query(_ request: ArchiveBrowseRequest) -> String? {
            URLComponents(url: InternetArchiveClient.searchURL(request, collection: request.isBooks ? .librivox : .liveMusic, page: 2, pageSize: 50),
                          resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        }
        XCTAssertEqual(query(.books(search: "dumas) OR *:*", language: "fre", sort: .popular)),
                       "collection:librivoxaudio AND (title:(dumas AND or*) OR creator:(dumas AND or*)) AND language:fre")
        XCTAssertEqual(query(.shows(artist: "GratefulDead) OR x", year: 1977)), "collection:GratefulDeadORx AND mediatype:etree AND year:1977")
        XCTAssertEqual(query(.artists(search: "", sort: .alphabetical)), "collection:etree AND mediatype:collection")
    }

    func testSearchParsingHandlesArraysAndPaging() throws {
        let json = """
        {"response": {"numFound": 120, "docs": [
          {"identifier": "a", "title": ["Show"], "creator": ["Band", "Other"], "date": "1977-05-08T00:00:00Z", "avg_rating": "4.5", "item_count": 12},
          {"title": "no identifier"}
        ]}}
        """
        let page = try InternetArchiveClient.parseSearch(data: Data(json.utf8), page: 2, pageSize: 50)
        XCTAssertEqual(page.results, [ArchiveSearchResult(id: "a", title: "Show", creator: "Band", date: "1977-05-08", year: 1977,
                                                          rating: 4.5, itemCount: 12)])
        XCTAssertTrue(page.hasMore)
        XCTAssertFalse(ArchiveSearchPage(results: [], total: 120, page: 3, pageSize: 50).hasMore)
    }

    func testResponseCacheExpiresButRemainsAvailableAsFallback() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(url: folder.appendingPathComponent("test.sqlite"))
        let start = Date(timeIntervalSince1970: 10_000)
        try store.saveArchiveResponse(Data("x".utf8), key: "k", now: start)
        XCTAssertEqual(try store.cachedArchiveResponse(key: "k", maxAge: 60, now: start.addingTimeInterval(30)), Data("x".utf8))
        XCTAssertNil(try store.cachedArchiveResponse(key: "k", maxAge: 60, now: start.addingTimeInterval(61)))
        XCTAssertEqual(try store.cachedArchiveResponse(key: "k", maxAge: nil, now: start.addingTimeInterval(1_000)), Data("x".utf8))
        try store.pruneArchiveResponses(olderThan: 100, now: start.addingTimeInterval(101))
        XCTAssertNil(try store.cachedArchiveResponse(key: "k", maxAge: nil, now: start))
    }

    func testPruningKeepsSavedQueuedAndPlaylistItemsAndPreservesResume() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(url: folder.appendingPathComponent("test.sqlite"))
        let source = SourceRecord(kind: .internetArchive, name: "LibriVox", location: ArchiveCollection.librivox.location)
        try store.saveSource(source)
        XCTAssertEqual(source.archiveCollection, .librivox)
        func materialize(_ id: String, saved: Bool? = nil) throws -> TrackRecord {
            let track = TrackRecord(id: "t-\(id)", sourceID: source.id, title: id, remoteID: id)
            try store.materializeArchiveItem(ArchiveItemRecord(sourceID: source.id, identifier: id, title: id), tracks: [track], saved: saved)
            return track
        }
        _ = try materialize("saved", saved: true)
        let queued = try materialize("queued")
        let listed = try materialize("listed")
        _ = try materialize("browsed")
        try store.saveQueue(trackIDs: [queued.id], currentIndex: 0, position: 0)
        _ = try store.savePlaylist(name: "Mix", trackIDs: [listed.id])
        try store.saveArchiveResume(sourceID: source.id, identifier: "saved", trackID: "t-saved", position: 42)

        XCTAssertTrue(try store.pruneArchiveTracks(sourceID: source.id))
        XCTAssertEqual(Set(try store.tracks(sourceID: source.id).map(\.id)), ["t-saved", "t-queued", "t-listed"])
        XCTAssertEqual(try store.track(id: "t-browsed")?.isAvailable, false)

        // Opening an item again restores its tracks without losing saved state or the resume point.
        _ = try materialize("saved")
        _ = try materialize("browsed")
        let saved = try store.archiveItem(sourceID: source.id, identifier: "saved")
        XCTAssertEqual(saved?.isSaved, true)
        XCTAssertEqual(saved?.resumeTrackID, "t-saved")
        XCTAssertEqual(saved?.resumePosition, 42)
        XCTAssertEqual(try store.track(id: "t-browsed")?.isAvailable, true)
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension ArchiveBrowseRequest {
    var isBooks: Bool { if case .books = self { return true }; return false }
}
