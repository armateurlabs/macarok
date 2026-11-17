import Foundation
import XCTest
@testable import MacarokAudio

final class PrematureEndTests: XCTestCase {
    private let remote = URL(string: "https://music.example/rest/stream.view?id=1")
    private let local = URL(fileURLWithPath: "/Music/track.flac")

    func testRemoteMediaStoppingHalfwayIsAnInterruptionButANaturalEndIsNot() {
        XCTAssertTrue(VLCPlaybackEngine.endedPrematurely(stream: nil, mediaURL: remote, position: 200, mediaLength: 400,
                                                         durationHint: 400, segmentEnd: nil, live: false))
        XCTAssertFalse(VLCPlaybackEngine.endedPrematurely(stream: nil, mediaURL: remote, position: 399.4, mediaLength: 400,
                                                          durationHint: 400, segmentEnd: nil, live: false), "The final samples end normally.")
        XCTAssertFalse(VLCPlaybackEngine.endedPrematurely(stream: nil, mediaURL: local, position: 200, mediaLength: 400,
                                                          durationHint: 400, segmentEnd: nil, live: false), "Local files always end normally.")
        XCTAssertFalse(VLCPlaybackEngine.endedPrematurely(stream: nil, mediaURL: remote, position: 200, mediaLength: 400,
                                                          durationHint: 400, segmentEnd: 250, live: false), "CUE segments have their own end.")
        XCTAssertFalse(VLCPlaybackEngine.endedPrematurely(stream: nil, mediaURL: remote, position: 200, mediaLength: 0,
                                                          durationHint: 400, segmentEnd: nil, live: false), "Without a decoded length, do not guess.")
        XCTAssertFalse(VLCPlaybackEngine.endedPrematurely(stream: nil, mediaURL: remote, position: 20, mediaLength: 400,
                                                          durationHint: nil, segmentEnd: nil, live: true), "Radio has no end.")
    }

    func testStreamsUseTheirTransferStateAndTrustTheLibraryDurationOnlyWithoutAKnownSize() {
        let failed = StubStream(error: URLError(.networkConnectionLost), size: 10_000_000)
        XCTAssertTrue(VLCPlaybackEngine.endedPrematurely(stream: failed, mediaURL: nil, position: 380, mediaLength: 0,
                                                         durationHint: 400, segmentEnd: nil, live: false))
        let complete = StubStream(error: nil, size: 10_000_000)
        XCTAssertFalse(VLCPlaybackEngine.endedPrematurely(stream: complete, mediaURL: nil, position: 120, mediaLength: 0,
                                                          durationHint: 400, segmentEnd: nil, live: false),
                       "A fully received file of known size ended where its audio ends.")
        let transcode = StubStream(error: nil, size: nil)
        XCTAssertTrue(VLCPlaybackEngine.endedPrematurely(stream: transcode, mediaURL: nil, position: 120, mediaLength: 0,
                                                         durationHint: 400, segmentEnd: nil, live: false))
        XCTAssertFalse(VLCPlaybackEngine.endedPrematurely(stream: transcode, mediaURL: nil, position: 392, mediaLength: 0,
                                                          durationHint: 400, segmentEnd: nil, live: false))
    }
}

private final class StubStream: InputStream {
    private let failure: Error?
    private let size: Int?
    init(error: Error?, size: Int?) { failure = error; self.size = size; super.init(data: Data()) }
    override var streamError: Error? { failure }
    override func property(forKey key: Stream.PropertyKey) -> Any? {
        key.rawValue == "NSStreamFileSizeKey" ? size.map { NSNumber(value: $0) } : nil
    }
}
