import XCTest
@testable import MacarokCore

final class LibraryOrderTests: XCTestCase {
    func testMissingDiscNumberAndDiscOneStillOrderByTrackNumber() {
        let later = track("a", disc: nil, number: 2)
        let earlier = track("z", disc: 1, number: 1)

        XCTAssertTrue(TrackRecord.libraryOrder(earlier, later))
        XCTAssertFalse(TrackRecord.libraryOrder(later, earlier))
        XCTAssertEqual([later, earlier].sorted(by: TrackRecord.libraryOrder).map(\.id), ["z", "a"])
    }

    func testMissingTrackNumberAndZeroContinueToTitleAndStableIdentity() {
        let values = [
            track("z", disc: 1, number: nil, title: "Beta"),
            track("b", disc: 1, number: 0, title: "Alpha"),
            track("a", disc: nil, number: nil, title: "Alpha")
        ]

        XCTAssertEqual(values.sorted(by: TrackRecord.libraryOrder).map(\.id), ["a", "b", "z"])
        XCTAssertEqual(Array(values.reversed()).sorted(by: TrackRecord.libraryOrder).map(\.id), ["a", "b", "z"])
    }

    func testOrderingIsStrictAndTransitiveAcrossMissingAndDefaultNumbers() {
        let discs: [Int?] = [nil, 1, 2]
        let numbers: [Int?] = [nil, 0, 1, 2]
        var values: [TrackRecord] = []
        for disc in discs {
            for number in numbers {
                values.append(track("track-\(values.count)", disc: disc, number: number))
            }
        }
        let less = TrackRecord.libraryOrder
        func equivalent(_ left: TrackRecord, _ right: TrackRecord) -> Bool {
            !less(left, right) && !less(right, left)
        }

        for first in values {
            XCTAssertFalse(less(first, first), "Ordering must be irreflexive.")
            for second in values {
                if less(first, second) { XCTAssertFalse(less(second, first), "Ordering must be asymmetric.") }
                for third in values {
                    if less(first, second) && less(second, third) {
                        XCTAssertTrue(less(first, third), "Ordering must be transitive.")
                    }
                    if equivalent(first, second) && equivalent(second, third) {
                        XCTAssertTrue(equivalent(first, third), "Equivalent ordering keys must be transitive.")
                    }
                }
            }
        }
    }

    func testAlbumYearUsesTheFirstKnownYearInNormalizedTrackOrder() {
        var second = track("a", disc: nil, number: 2)
        second.year = 2004
        var first = track("z", disc: 1, number: 1)
        first.year = 1999

        let album = AlbumRecord(tracks: [second, first])

        XCTAssertEqual(album.tracks.map(\.id), ["z", "a"])
        XCTAssertEqual(album.year, 1999)
        first.year = nil
        XCTAssertEqual(AlbumRecord(tracks: [second, first]).year, 2004)
    }

    private func track(_ id: String, disc: Int?, number: Int?, title: String = "Track") -> TrackRecord {
        TrackRecord(id: id, sourceID: "library-order", albumID: "album", title: title,
                    artist: "Artist", album: "Album", trackNumber: number, discNumber: disc)
    }
}
