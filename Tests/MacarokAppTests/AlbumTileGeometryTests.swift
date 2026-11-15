import AppKit
import MacarokCore
import SwiftUI
import XCTest
@testable import MacarokApp

@MainActor
final class AlbumTileGeometryTests: XCTestCase {
    func testMixedTitlesAndArtworkKeepAlbumCardsAlignedInBothAppearances() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokAlbumGeometry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = SourceRecord(id: "geometry-local", kind: .local, name: "Local Files", location: directory.absoluteString)
        let remote = SourceRecord(id: "geometry-remote", kind: .openSubsonic, name: "Music Server", location: "https://music.invalid")
        let artwork: [String?] = [nil,
            try makeArtwork(size: NSSize(width: 80, height: 80), at: directory.appendingPathComponent("square.png")),
            try makeArtwork(size: NSSize(width: 50, height: 100), at: directory.appendingPathComponent("portrait.png")),
            try makeArtwork(size: NSSize(width: 100, height: 50), at: directory.appendingPathComponent("landscape.png"))]
        let titles = ["Short", "A longer album title that needs two lines", "Another Short Title", "A very long album title that must truncate after its second line"]
        let albums = titles.enumerated().map { index, title in
            AlbumRecord(tracks: [TrackRecord(id: "geometry-track-\(index)", sourceID: index.isMultiple(of: 2) ? local.id : remote.id,
                albumID: "geometry-album-\(index)", title: "Example Track", artist: "Example Artist", album: title,
                artworkPath: artwork[index])])
        }
        let model = AppModel(preferences: AppPreferences(), registerSystemControls: false)
        model.sources = [local, remote]

        for allSources in [false, true] {
            model.libraryScope = allSources ? .all : .source(local.id)
            for appearance in [ColorScheme.light, .dark] {
                for (width, columns) in [(CGFloat(328), 2), (CGFloat(552), 3)] {
                    let capture = AlbumFrameCapture()
                    let root = AlbumGeometryGrid(model: model, albums: albums, columns: columns, capture: capture)
                        .frame(width: width, height: 580, alignment: .topLeading)
                        .environment(\.colorScheme, appearance)
                    let hosting = NSHostingView(rootView: root)
                    hosting.sizingOptions = []
                    hosting.frame = NSRect(x: 0, y: 0, width: width, height: 580)
                    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: true)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: appearance == .light ? .aqua : .darkAqua)
                    window.contentView = hosting
                    defer { window.contentView = nil; window.close() }

                    for _ in 0..<100 {
                        hosting.layoutSubtreeIfNeeded()
                        if capture.frames.count == albums.count { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let initial = capture.frames
                    XCTAssertEqual(initial.count, albums.count)
                    // Let local image tasks settle; aspect ratios must not change card geometry.
                    for _ in 0..<12 {
                        hosting.layoutSubtreeIfNeeded()
                        await Task.yield()
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    try assertAligned(capture.frames, albums: albums, columns: columns)
                    for album in albums {
                        let before = try XCTUnwrap(initial[album.presentationID])
                        let after = try XCTUnwrap(capture.frames[album.presentationID])
                        XCTAssertEqual(before.minY, after.minY, accuracy: 1)
                        XCTAssertEqual(before.height, after.height, accuracy: 1)
                    }
                    XCTAssertFalse(window.isVisible)
                }
            }
        }
    }

    private func assertAligned(_ frames: [String: CGRect], albums: [AlbumRecord], columns: Int) throws {
        for start in stride(from: 0, to: albums.count, by: columns) {
            let row = Array(albums[start..<min(start + columns, albums.count)])
            let first = try XCTUnwrap(frames[row[0].presentationID])
            XCTAssertGreaterThan(first.width, 0)
            for album in row.dropFirst() {
                let frame = try XCTUnwrap(frames[album.presentationID])
                XCTAssertEqual(frame.minY, first.minY, accuracy: 1, "Album covers must share the same top edge.")
                XCTAssertEqual(frame.width, first.width, accuracy: 1)
                XCTAssertEqual(frame.height, first.height, accuracy: 1, "Reserved captions must align artists as well as artwork.")
            }
        }
    }

    private func makeArtwork(size: NSSize, at url: URL) throws -> String {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return url.path
    }
}

@MainActor
private final class AlbumFrameCapture {
    var frames: [String: CGRect] = [:]
}

private struct AlbumFramePreference: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

@MainActor
private struct AlbumGeometryGrid: View {
    let model: AppModel
    let albums: [AlbumRecord]
    let columns: Int
    let capture: AlbumFrameCapture

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: columns), alignment: .leading, spacing: 16) {
            ForEach(albums, id: \.presentationID) { album in
                AlbumTile(model: model, album: album)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: AlbumFramePreference.self,
                                value: [album.presentationID: geometry.frame(in: .named("album-geometry"))])
                        }
                    }
            }
        }
        .coordinateSpace(name: "album-geometry")
        .onPreferenceChange(AlbumFramePreference.self) { capture.frames = $0 }
    }
}
