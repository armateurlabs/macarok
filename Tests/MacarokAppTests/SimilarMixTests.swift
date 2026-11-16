import AppKit
import Foundation
import MacarokCore
import SwiftUI
import XCTest
@testable import MacarokApp

@MainActor
final class SimilarMixTests: XCTestCase {
    func testMixReplacesThePlaylistAnnouncesOneTrackAndEndsWhenItsEntriesLeave() async throws {
        let (model, tracks) = makeModel()
        defer { model.stopPlayback(clearCurrent: true) }
        model.queue = [QueueItem(track: track("old", "Old", "Band Z"))]
        model.similarity.startMix([tracks["seed"]!])
        XCTAssertEqual(model.queue.map(\.track.id), ["seed"])
        XCTAssertEqual(model.similarity.session?.title, "Seed Song")
        try await waitForSuggestion(model)
        XCTAssertEqual(model.queue.map(\.track.id), ["seed", "b1"], "Only the next track is announced, right after the current one.")
        XCTAssertTrue(model.similarity.isSuggestion(model.queue[1].id))

        model.queue = [QueueItem(track: track("old", "Old", "Band Z"))]
        XCTAssertFalse(model.similarity.isMixing, "Restoring an unrelated playlist, such as with Undo, ends the mix.")
    }

    func testSkippedTracksNeverReturnDuringTheSessionUntilRestored() async throws {
        let (model, tracks) = makeModel()
        defer { model.stopPlayback(clearCurrent: true) }
        model.similarity.startMix([tracks["seed"]!])
        var announced: [String] = []
        for _ in 0..<4 {
            try await waitForSuggestion(model)
            announced.append(model.queue[1].track.id)
            model.similarity.skipSuggestion()
        }
        XCTAssertEqual(announced, ["b1", "c1", "d1", "e1"])
        try await waitUntil { !model.similarity.isSearching }
        XCTAssertNil(model.similarity.session?.suggestionID)
        XCTAssertNotNil(model.similarity.error, "Every similar recording was skipped.")
        XCTAssertEqual(model.similarity.session?.skippedCount, 4)
        XCTAssertEqual(model.queue.map(\.track.id), ["seed"])

        model.similarity.restoreSkipped()
        model.similarity.retry()
        try await waitForSuggestion(model)
        XCTAssertEqual(model.queue[1].track.id, "b1")

        // Removing the announced entry from the playlist also skips it.
        model.removeQueue(IndexSet(integer: 1))
        try await waitForSuggestion(model)
        XCTAssertEqual(model.queue[1].track.id, "c1")
        XCTAssertEqual(model.similarity.session?.skippedCount, 1)
    }

    func testNextCountsAsSkipRepeatIsIgnoredAndTheMixWaitsForItsNextTrack() async throws {
        let (model, tracks) = makeModel()
        defer { model.stopPlayback(clearCurrent: true) }
        model.settings.repeatMode = .track
        model.similarity.startMix([tracks["seed"]!])
        try await waitForSuggestion(model)
        let suggestion = model.queue[1].id
        model.advance(manual: false)
        XCTAssertEqual(model.currentQueueID, suggestion, "Repeat Track does not apply during a mix.")
        try await waitUntil { model.queue.count == 3 }
        XCTAssertEqual(model.similarity.session?.played.map(\.id), ["seed", "b1"])
        XCTAssertEqual(model.queue[2].track.id, "c1")
        XCTAssertEqual(model.similarity.session?.skippedCount, 0)

        model.advance()
        XCTAssertEqual(model.currentTrack?.id, "c1")
        XCTAssertEqual(model.similarity.session?.skippedCount, 1, "Next skips the track that was playing.")
        XCTAssertTrue(model.similarity.session?.skipped.contains("b1") == true)

        // With nothing announced yet, Next waits and starts the next track as soon as it is found.
        try await waitUntil { model.queue.count == 4 }
        model.similarity.skipSuggestion()
        model.advance()
        try await waitUntil { model.currentTrack.map { !["c1", "d1"].contains($0.id) } == true }
        XCTAssertEqual(model.currentTrack?.id, "e1")
        XCTAssertTrue(model.similarity.isMixing)
    }

    func testFollowModesChooseSeedsAndFixedPlaylistsReplaceTheQueue() async throws {
        let seed = track("seed", "Seed Song", "Band A"), b = track("b1", "Song B", "Band B"), c = track("c1", "Song C", "Band C")
        var session = SimilarMixSession(seed: [seed], title: "Seed Song", subtitle: "Band A", played: [seed, b, c])
        session.skipped = ["c1"]
        XCTAssertEqual(SimilarityController.seeds(for: session, follow: .seed), [SimilaritySeed(seed)])
        XCTAssertEqual(SimilarityController.seeds(for: session, follow: .lastPlayed), [SimilaritySeed(b)], "A skipped track is not followed.")
        XCTAssertEqual(SimilarityController.seeds(for: session, follow: .blend), [SimilaritySeed(seed), SimilaritySeed(b, weight: 0.8)])

        let (model, tracks) = makeModel()
        defer { model.stopPlayback(clearCurrent: true) }
        model.similarity.startMix([tracks["seed"]!])
        try await waitForSuggestion(model)
        model.similarity.generatePlaylist([tracks["seed"]!], limit: 3)
        try await waitUntil { !model.similarity.isGenerating }
        XCTAssertFalse(model.similarity.isMixing, "A fixed playlist ends the mix.")
        XCTAssertEqual(model.queue.map(\.track.id), ["seed", "b1", "c1"], "The seed track opens a playlist within the limit.")
        model.similarity.generatePlaylist([tracks["seed"]!], limit: nil)
        try await waitUntil { !model.similarity.isGenerating }
        XCTAssertEqual(model.queue.map(\.track.id), ["seed", "b1", "c1", "d1", "e1"])
        XCTAssertEqual(SimilarityController.describe([tracks["b1"]!, tracks["c1"]!]).title, "2 tracks")
    }

    func testStopAndClearEndTheMixAndRemoveTheAnnouncedTrack() async throws {
        let (model, tracks) = makeModel()
        defer { model.stopPlayback(clearCurrent: true) }
        model.similarity.startMix([tracks["seed"]!])
        try await waitForSuggestion(model)
        model.similarity.end()
        XCTAssertFalse(model.similarity.isMixing)
        XCTAssertEqual(model.queue.map(\.track.id), ["seed"])
        model.similarity.startMix([tracks["seed"]!])
        try await waitForSuggestion(model)
        model.clearQueue()
        XCTAssertFalse(model.similarity.isMixing)
        XCTAssertFalse(model.queue.contains { $0.track.id == "b1" })
    }

    private func makeModel() -> (AppModel, [String: TrackRecord]) {
        let model = AppModel(registerSystemControls: false)
        let library = [track("seed", "Seed Song", "Band A"), track("b1", "Song B", "Band B"), track("c1", "Song C", "Band C"),
                       track("d1", "Song D", "Band D"), track("e1", "Song E", "Band E")]
        let provider = MockMixProvider(
            tracks: ["band a|seed song": [SimilarTrack(artist: "Band B", title: "Song B", score: 0.9),
                                          SimilarTrack(artist: "Band C", title: "Song C", score: 0.8)]],
            artists: ["band a": [SimilarArtist(name: "Band D", score: 0.5), SimilarArtist(name: "Band E", score: 0.4)]])
        model.similarity.serviceOverride = SimilarityService(providers: [provider])
        model.similarity.libraryOverride = SimilarityLibrary(tracks: library)
        model.similarity.chooseNext = { candidates, _ in candidates.first?.track }
        return (model, Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) }))
    }

    private func waitForSuggestion(_ model: AppModel) async throws {
        try await waitUntil { model.similarity.session?.suggestionID != nil && !model.similarity.isSearching }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out waiting for the mix.")
    }

    private func track(_ id: String, _ title: String, _ artist: String) -> TrackRecord {
        TrackRecord(id: id, sourceID: "source", albumID: "album-\(id)", title: title, artist: artist, album: "Album", duration: 100)
    }
}

private struct MockMixProvider: SimilarityProvider {
    let name = "mock"
    let tracks: [String: [SimilarTrack]]
    let artists: [String: [SimilarArtist]]
    func similarTracks(artist: String, title: String) async throws -> [SimilarTrack] { tracks["\(artist.lowercased())|\(title.lowercased())"] ?? [] }
    func similarArtists(artist: String) async throws -> [SimilarArtist] { artists[artist.lowercased()] ?? [] }
}

@MainActor
final class SimilarMixRenderingTests: XCTestCase {
    func testNativeMixAndSheetRenderInBothAppearances() async throws {
        guard let path = ProcessInfo.processInfo.environment["MACAROK_SNAPSHOT_DIRECTORY"], !path.isEmpty else {
            throw XCTSkip("Set MACAROK_SNAPSHOT_DIRECTORY to render the similarity views.")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let model = AppModel(registerSystemControls: false)
        defer { model.stopPlayback(clearCurrent: true) }
        func track(_ id: String, _ title: String, _ artist: String) -> TrackRecord {
            TrackRecord(id: id, sourceID: "source", albumID: "album-\(id)", title: title, artist: artist, album: "Album \(id)", duration: 200)
        }
        let seed = track("seed", "First Light", "Meridian Atlas")
        let library = [seed, track("b1", "Night Geometry", "Paper Satellites"), track("c1", "Quiet Streets", "North Window")]
        let provider = MockMixProvider(tracks: ["meridian atlas|first light": [SimilarTrack(artist: "Paper Satellites", title: "Night Geometry", score: 0.9)]],
                                       artists: ["meridian atlas": [SimilarArtist(name: "North Window", score: 0.6)]])
        model.similarity.serviceOverride = SimilarityService(providers: [provider])
        model.similarity.libraryOverride = SimilarityLibrary(tracks: library)
        model.similarity.chooseNext = { candidates, _ in candidates.first?.track }
        model.similarity.startMix([seed])
        for _ in 0..<200 where model.similarity.session?.suggestionID == nil { try await Task.sleep(for: .milliseconds(10)) }
        model.similarity.skipSuggestion()
        for _ in 0..<200 where model.similarity.session?.suggestionID == nil { try await Task.sleep(for: .milliseconds(10)) }
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            try await render(QueuePane(model: model, player: model.player), size: NSSize(width: 360, height: 420), scheme: scheme,
                             destination: output.appendingPathComponent("similar-mix-\(suffix).png"))
            for dynamic in [false, true] {
                try await render(SimilarPlaylistSheet(model: model, request: SimilarityRequest(seed: [seed], dynamic: dynamic)),
                                 size: NSSize(width: 460, height: 470), scheme: scheme,
                                 destination: output.appendingPathComponent("similar-sheet-\(dynamic ? "dynamic" : "fixed")-\(suffix).png"))
            }
        }
        model.similarity.skipSuggestion()
        for _ in 0..<200 where model.similarity.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        try await render(QueuePane(model: model, player: model.player), size: NSSize(width: 360, height: 420), scheme: .dark,
                         destination: output.appendingPathComponent("similar-mix-exhausted-dark.png"))
    }

    private func render<Content: View>(_ content: Content, size: NSSize, scheme: ColorScheme, destination: URL) async throws {
        let appearance = try XCTUnwrap(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
        let hosting = NSHostingView(rootView: content.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = appearance
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        for _ in 0..<12 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination)
    }
}
