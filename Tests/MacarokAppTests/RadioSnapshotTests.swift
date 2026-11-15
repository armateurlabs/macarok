import Foundation
import XCTest
import MacarokCore
@testable import MacarokApp

final class RadioSnapshotTests: XCTestCase {
    func testStationsResolveByIdentityWithoutCreatingMusicAlbumsOrHistory() throws {
        let source = SourceRecord(id: "music", kind: .local, name: "Music", location: "/tmp/synthetic")
        let music = TrackRecord(id: "music-track", sourceID: source.id, title: "Song", artist: "Artist", album: "Album", playCount: 2)
        var radio = RadioStationRecord(name: "Station", streamURL: "https://radio.invalid/live").track
        radio.playCount = 20; radio.lastPlayedAt = Date()
        let snapshot = try LibrarySnapshot.build(scope: .all, tracks: [music,radio], sources: [source,RadioLibrary.source])
        XCTAssertEqual(snapshot.tracks.map(\.id), [music.id])
        XCTAssertEqual(snapshot.stations.map(\.id), [radio.id])
        XCTAssertEqual(snapshot.tracksByID[radio.id]?.title, "Station")
        XCTAssertEqual(snapshot.albums.count, 1)
        XCTAssertEqual(snapshot.artists.map(\.name), ["Artist"])
        XCTAssertTrue(snapshot.recentlyPlayed.isEmpty)
        XCTAssertEqual(snapshot.mostPlayedTracks.map(\.id), [music.id])
        XCTAssertEqual(snapshot.folderNodes.map(\.name), [source.name])
    }
}
