import AppKit
import CoreGraphics
import MacarokAudio
import MacarokCore
import SwiftUI
import XCTest
@testable import MacarokApp

@MainActor
final class MenuBarMiniPlayerTests: XCTestCase {
    func testPresentationGuardsUnavailableActionsAndUsesReconnectForDisconnectedRadio() {
        let player = MenuBarPlayerPresentation(timeline: VLCPlaybackEngine().timeline)
        var actions: [MenuBarPlayerPresentation.Action] = []
        player.action = { actions.append($0) }
        for action in MenuBarPlayerPresentation.Action.allCases { player.perform(action) }
        XCTAssertTrue(actions.isEmpty)
        player.state = .init(enabled: true)
        player.perform(.playPause); player.perform(.next); player.perform(.previous)
        XCTAssertTrue(actions.isEmpty)
        player.perform(.showWindow)
        XCTAssertEqual(actions, [.showWindow])
        player.state.canPlay = true; player.state.hasQueue = true
        player.state.isRadio = true; player.state.reconnect = true
        XCTAssertEqual(player.state.playPauseTitle, "Reconnect")
        XCTAssertEqual(player.state.playPauseSymbol, "arrow.clockwise")
        player.perform(.playPause)
        XCTAssertEqual(actions, [.showWindow, .playPause])
        player.state.active = true
        XCTAssertEqual(player.state.playPauseTitle, "Pause")
        XCTAssertEqual(player.state.playPauseSymbol, "pause.fill")
    }

    func testMiniPlayerRendersLoadedArtworkAndNativeThemeInBothAppearances() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokMiniPlayerArtwork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cover.png")
        try cover(red: 0.82, green: 0.18, blue: 0.08).write(to: file)
        for appearance in [Appearance.light, .dark] {
            let player = MenuBarPlayerPresentation(timeline: VLCPlaybackEngine().timeline)
            player.state = .init(enabled: true,
                track: TrackRecord(id: "mini", sourceID: "synthetic", title: "A Long Recording Title That Occupies Two Lines", artist: "Synthetic Artist", album: "The Album", artworkPath: file.path),
                artist: "Synthetic Artist", phase: .paused, canPlay: true, hasQueue: true, appearance: appearance)
            var remoteArtworkRequests = 0
            player.prepareArtwork = { remoteArtworkRequests += 1 }
            let rendered = try await render(player, name: "menu-bar-mini-player-\(appearance.rawValue)")
            defer { rendered.close() }
            XCTAssertEqual(remoteArtworkRequests, 0, "A local thumbnail must not initiate artwork retrieval.")
            XCTAssertGreaterThan(coloredPixels(in: rendered.bitmap, color: .red), 4_000, "The player must display the actual cover, not only a placeholder.")
            XCTAssertEqual(rendered.hosting.bounds.width, 320, accuracy: 0.5)
            XCTAssertGreaterThan(rendered.hosting.bounds.height, 240)
            XCTAssertLessThan(rendered.hosting.bounds.height, 450, "The status popover should remain compact.")
            XCTAssertFalse(rendered.window.isVisible)
        }
    }

    func testArtworkRevisionReloadsAReplacedCoverWithoutChangingThePlayingIdentity() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokMiniPlayerRevision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cover.png")
        try cover(red: 0.82, green: 0.18, blue: 0.08).write(to: file)
        let player = MenuBarPlayerPresentation(timeline: VLCPlaybackEngine().timeline)
        player.state = .init(enabled: true,
            track: TrackRecord(id: "same", sourceID: "synthetic", title: "Unchanged Recording", artist: "Artist", album: "Album", artworkPath: file.path),
            artist: "Artist", canPlay: true, hasQueue: true, appearance: .dark)
        let rendered = try await render(player)
        defer { rendered.close() }
        XCTAssertGreaterThan(coloredPixels(in: rendered.bitmap, color: .red), 4_000)
        try cover(red: 0.08, green: 0.2, blue: 0.85).write(to: file, options: .atomic)
        player.state.artworkRevision += 1
        let bitmap = try await capture(rendered.hosting)
        XCTAssertGreaterThan(coloredPixels(in: bitmap, color: .blue), 4_000)
        XCTAssertLessThan(coloredPixels(in: bitmap, color: .red), 100)
        XCTAssertEqual(player.state.track?.id, "same")
    }

    func testPodcastChaptersShowTheCurrentChapterAndChapterButtons() async throws {
        _ = NSApplication.shared
        let player = MenuBarPlayerPresentation(timeline: VLCPlaybackEngine().timeline)
        var actions: [MenuBarPlayerPresentation.Action] = []
        player.action = { actions.append($0) }
        player.state = .init(enabled: true, track: TrackRecord(id: "episode", sourceID: "show", title: "Microphones in the Snow", artist: "Paper Satellites",
                             album: "Field Notes Weekly", duration: 2_220), artist: "Paper Satellites", phase: .paused, canPlay: true, hasQueue: true)
        player.perform(.nextChapter)
        XCTAssertTrue(actions.isEmpty, "Without chapters there is nothing to move to.")
        player.state.chapters = [PodcastChapter(start: 0, title: "Introduction"), PodcastChapter(start: 192, title: "The valley")]
        player.state.canSeekChapters = true
        player.perform(.previousChapter); player.perform(.nextChapter)
        XCTAssertEqual(actions, [.previousChapter, .nextChapter])
        for appearance in [Appearance.light, .dark] {
            player.state.appearance = appearance
            let rendered = try await render(player, name: "menu-bar-mini-player-chapters-\(appearance.rawValue)")
            defer { rendered.close() }
            XCTAssertEqual(rendered.hosting.bounds.width, 320, accuracy: 0.5, "Chapter buttons must fit the compact popover.")
        }
    }

    func testRadioAndEmptyStatesRenderWithoutArtworkOrSeekAssumptions() async throws {
        _ = NSApplication.shared
        for appearance in [Appearance.light, .dark] {
            for isRadio in [false, true] {
                let player = MenuBarPlayerPresentation(timeline: VLCPlaybackEngine().timeline)
                let track = isRadio ? TrackRecord(id: "station", sourceID: "radio", title: "Synthetic Radio Station", artist: "Internet Radio") : nil
                player.state = .init(enabled: true, track: track, artist: isRadio ? "Artist — Current broadcast" : "",
                    canPlay: isRadio, hasQueue: isRadio, isRadio: isRadio, reconnect: isRadio, appearance: appearance)
                let name = "menu-bar-mini-player-\(isRadio ? "radio" : "empty")-\(appearance.rawValue)"
                let rendered = try await render(player, name: name)
                defer { rendered.close() }
                XCTAssertEqual(player.state.title, isRadio ? "Synthetic Radio Station" : "Nothing playing")
                XCTAssertEqual(player.state.playPauseTitle, isRadio ? "Reconnect" : "Play")
                XCTAssertEqual(rendered.hosting.bounds.width, 320, accuracy: 0.5)
                XCTAssertGreaterThan(rendered.bitmap.pixelsHigh, 0)
            }
        }
    }

    private enum CoverColor { case red, blue }
    private func coloredPixels(in bitmap: NSBitmapImageRep, color: CoverColor) -> Int {
        var matches = 0
        // Sample alternate pixels; the threshold remains below a 96-point cover even at 1x.
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color == .red, pixel.redComponent > 0.7, pixel.greenComponent < 0.35, pixel.blueComponent < 0.25 { matches += 4 }
                if color == .blue, pixel.blueComponent > 0.7, pixel.redComponent < 0.25, pixel.greenComponent < 0.4 { matches += 4 }
            }
        }
        return matches
    }

    private func cover(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 240, height: 120, bitsPerComponent: 8,
            bytesPerRow: 240 * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 120))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
    }

    @MainActor private struct Rendered {
        let hosting: NSHostingView<MenuBarMiniPlayerView>
        let window: NSWindow
        let bitmap: NSBitmapImageRep
        func close() { window.contentView = nil; window.close() }
    }
    private func render(_ player: MenuBarPlayerPresentation, name: String? = nil) async throws -> Rendered {
        let hosting = NSHostingView(rootView: MenuBarMiniPlayerView(player: player))
        let fitting = hosting.fittingSize
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: fitting)
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: player.state.appearance == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        let bitmap = try await capture(hosting)
        if let name, let path = ProcessInfo.processInfo.environment["MACAROK_SNAPSHOT_DIRECTORY"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name).png"))
        }
        return Rendered(hosting: hosting, window: window, bitmap: bitmap)
    }
    private func capture(_ hosting: NSHostingView<MenuBarMiniPlayerView>) async throws -> NSBitmapImageRep {
        for _ in 0..<16 { hosting.layoutSubtreeIfNeeded(); await Task.yield(); try await Task.sleep(for: .milliseconds(15)) }
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }
}
