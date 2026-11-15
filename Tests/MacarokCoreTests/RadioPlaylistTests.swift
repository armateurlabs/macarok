import Foundation
import XCTest
@testable import MacarokCore

final class RadioPlaylistTests: XCTestCase {
    func testBothPlaylistFormatsRoundTripExplicitLiveIdentityAndUnknownDuration() throws {
        let station = RadioStationRecord(name: "Station Name", streamURL: "https://radio.invalid/live?channel=one", directoryID: UUID().uuidString)
        let entry = PlaylistEntry(track: station.track)
        XCTAssertTrue(entry.isLiveRadio)
        XCTAssertEqual(entry.title, "Station Name")
        XCTAssertNil(entry.duration)
        for format in [PlaylistFileFormat.m3u, .pls] {
            let file = URL(fileURLWithPath: "/playlists/radio.\(format.rawValue)")
            let text = try PlaylistIO.serialize(entries: [entry, entry], format: format)
            XCTAssertTrue(text.contains(format == .m3u ? "#EXTINF:-1,Station Name" : "Length1=-1"))
            XCTAssertTrue(text.contains(format == .m3u ? "#MACAROK-MEDIA-KIND:radio" : "MediaKind1=radio"))
            XCTAssertEqual(PlaylistIO.parse(text: text, playlistURL: file), [entry, entry])
        }
    }

    func testLegacyRadioSourceCommentRemainsLiveWithoutNewMarker() {
        let text = "#EXTM3U\n#EXTINF:0,Old Station\n#MACAROK-SOURCE-ID:\(RadioLibrary.sourceID)\n#MACAROK-TRACK-ID:legacy\nhttps://radio.invalid/live\n"
        let entry = PlaylistIO.parse(text: text, playlistURL: URL(fileURLWithPath: "/radio.m3u")).first
        XCTAssertEqual(entry?.isLiveRadio, true)
        XCTAssertNil(entry?.duration)
        XCTAssertEqual(entry?.trackID, "legacy")
    }

    func testLiveMarkerDoesNotLeakToFollowingMusicAndUnknownDurationDoesNotImplyLive() throws {
        let live = PlaylistEntry(url: URL(string: "https://radio.invalid/live")!, title: "Radio", startTime: 30, endTime: 60, isLiveRadio: true)
        XCTAssertNil(live.startTime); XCTAssertNil(live.endTime)
        let finite = PlaylistEntry(url: URL(string: "https://music.invalid/song.mp3")!, title: "Song", duration: nil)
        let cue = PlaylistEntry(url: URL(fileURLWithPath: "/music/album.flac"), title: "CUE Track", duration: 90, startTime: 15, endTime: 105)
        let text = try PlaylistIO.serialize(entries: [live, finite, cue])
        let parsed = PlaylistIO.parse(text: text, playlistURL: URL(fileURLWithPath: "/mixed.m3u"))
        XCTAssertEqual(parsed, [live, finite, cue])
        XCTAssertEqual(parsed.map(\.isLiveRadio), [true, false, false])
        XCTAssertEqual(parsed.last?.startTime, 15)
    }
}
