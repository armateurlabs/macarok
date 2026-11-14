import Foundation
import XCTest
@testable import MacarokCore

final class CUEParserTests: XCTestCase {
    func testFramesRemainExactAndPregapsArePreserved() throws {
        let sheet = try CUEParser.parse("""
            REM DATE 1973
            REM GENRE "Progressive Rock"
            PERFORMER "Pink Floyd"
            TITLE "The Dark Side of the Moon"
            FILE "album.flac" WAVE
              TRACK 01 AUDIO
                TITLE "Speak to Me"
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                TITLE "Breathe"
                INDEX 00 01:07:37
                INDEX 01 01:08:00
            """)
        XCTAssertEqual(sheet.title, "The Dark Side of the Moon")
        XCTAssertEqual(sheet.year, 1973)
        XCTAssertEqual(sheet.genre, "Progressive Rock")
        XCTAssertEqual(sheet.tracks[1].index00?.frames, 5_062)
        XCTAssertEqual(sheet.tracks[1].index01.frames, 5_100)
        XCTAssertEqual(sheet.tracks[1].index01.seconds, 68)
        XCTAssertEqual(try CUETime("00:01:37").seconds, 112.0 / 75, accuracy: 0.000_000_001)
    }

    func testMultiFileSheetsResetTimestampsAndPreserveEscapedQuotes() throws {
        let sheet = try CUEParser.parse(#"""
            TITLE "An \"Album\""
            FILE "Disc 1\album.flac" WAVE
              TRACK 01 AUDIO
                TITLE "The \"First\" Track"
                INDEX 01 00:00:00
            FILE "Disc 2\album.flac" WAVE
              TRACK 02 AUDIO
                INDEX 01 00:00:00
            """#)
        XCTAssertEqual(sheet.title, "An \"Album\"")
        XCTAssertEqual(sheet.tracks[0].title, "The \"First\" Track")
        XCTAssertEqual(sheet.fileNames, ["Disc 1\\album.flac", "Disc 2\\album.flac"])
    }

    func testMalformedIndexAndDuplicateTrackAreRejected() {
        XCTAssertThrowsError(try CUETime("00:60:00"))
        XCTAssertThrowsError(try CUETime("00:01:75"))
        XCTAssertThrowsError(try CUEParser.parse("FILE album.flac WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nTRACK 01 AUDIO\nINDEX 01 01:00:00"))
        XCTAssertThrowsError(try CUEParser.parse("FILE album.flac WAVE\nTRACK 01 AUDIO\nTITLE Missing"))
    }
}
