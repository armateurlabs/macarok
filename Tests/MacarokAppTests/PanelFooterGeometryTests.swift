import AppKit
import Foundation
import MacarokCore
import SwiftUI
import XCTest
@testable import MacarokApp

@MainActor
final class PanelFooterGeometryTests: XCTestCase {
    func testPanelFootersShareOneStableRowAcrossRefreshStatesAndAppearances() async throws {
        _ = NSApplication.shared
        let model = AppModel(preferences: AppPreferences(), registerSystemControls: false)
        model.sources = [SourceRecord(id: "footer-source", kind: .openSubsonic, name: "Library", location: "https://preview.invalid")]
        model.libraryScope = .all
        let output = try outputDirectory()
        for scheme in [ColorScheme.light, .dark] {
            for widths in [(CGFloat(245), CGFloat(270)), (255, 270), (295, 330), (296, 330), (360, 330), (361, 330), (440, 480)] {
                try await render(model: model, libraryWidth: widths.0, playlistWidth: widths.1, scheme: scheme, output: output)
            }
        }
    }

    private func render(model: AppModel, libraryWidth: CGFloat, playlistWidth: CGFloat,
                        scheme: ColorScheme, output: URL?) async throws {
        let size = NSSize(width: libraryWidth + playlistWidth + 1, height: 71)
        let appearance = try XCTUnwrap(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
        let hosting = NSHostingView(rootView: FooterGeometryFixture(model: model, libraryWidth: libraryWidth, playlistWidth: playlistWidth)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "en_US")))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = appearance
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.setContentSize(size)
        defer { window.contentView = nil; window.close() }
        var originalFrames: [NSRect]?
        let states = ["idle", "refreshing", "reconnecting", "stopping"]
        for state in states {
            model.isRefreshing = state != "idle"
            model.isStoppingRefresh = state == "stopping"
            model.refreshProgress = state == "reconnecting" ? "Reconnecting to the server and preserving the partial index…" : "Imported 2,391 albums · 25,869 tracks"
            for _ in 0..<6 {
                hosting.layoutSubtreeIfNeeded()
                await Task.yield()
                try await Task.sleep(for: .milliseconds(10))
            }
            let probes = descendants(hosting).compactMap { $0 as? FooterGeometryProbeView }
            let library = try XCTUnwrap(probes.first { $0.identifier?.rawValue == "library" })
            let playlist = try XCTUnwrap(probes.first { $0.identifier?.rawValue == "playlist" })
            let status = try XCTUnwrap(probes.first { $0.identifier?.rawValue == "status" })
            let frames = [library, playlist, status].map { $0.convert($0.bounds, to: hosting) }
            XCTAssertEqual(frames[0].height, 42, accuracy: 0.5)
            XCTAssertEqual(frames[1].height, 42, accuracy: 0.5)
            XCTAssertEqual(frames[2].height, 29, accuracy: 0.5)
            XCTAssertEqual(frames[0].width, libraryWidth, accuracy: 0.5)
            XCTAssertEqual(frames[1].width, playlistWidth, accuracy: 0.5)
            XCTAssertEqual(frames[0].midY, frames[1].midY, accuracy: 0.5)
            for frame in frames {
                XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
                XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5)
                XCTAssertGreaterThanOrEqual(frame.minY, -0.5)
                XCTAssertLessThanOrEqual(frame.maxY, size.height + 0.5)
            }
            if let originalFrames { XCTAssertEqual(frames, originalFrames, "Refresh and reconnect text must never resize either panel toolbar.") }
            else { originalFrames = frames }
            hosting.displayIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let libraryColor = try color(at: NSPoint(x: frames[0].minX + 4, y: frames[0].midY), hosting: hosting, bitmap: bitmap)
            let playlistColor = try color(at: NSPoint(x: frames[1].minX + 4, y: frames[1].midY), hosting: hosting, bitmap: bitmap)
            let statusColor = try color(at: NSPoint(x: frames[2].minX + 4, y: frames[2].midY), hosting: hosting, bitmap: bitmap)
            XCTAssertLessThan(distance(libraryColor, playlistColor), 0.01, "Both panel footers use the same native background.")
            XCTAssertGreaterThan(distance(libraryColor, statusColor), 0.015, "The panel toolbar surface must remain distinct from the full-width window status bar.")
            for (frame, background) in zip(frames.prefix(2), [libraryColor, playlistColor]) {
                let interiorY = hosting.isFlipped ? frame.minY + 5 : frame.maxY - 5
                let interior = try color(at: NSPoint(x: frame.midX, y: interiorY), hosting: hosting, bitmap: bitmap)
                XCTAssertLessThan(distance(interior, background), 0.01, "The footer interior must not contain a vertical divider.")
                let top = hosting.isFlipped ? frame.minY + 0.1 : frame.maxY - 0.1
                let separator = try color(at: NSPoint(x: frame.minX + 4, y: top), hosting: hosting, bitmap: bitmap)
                XCTAssertGreaterThan(distance(separator, background), 0.01, "Each panel footer needs a full-width horizontal top separator.")
            }
            if let output, [CGFloat(245), 440].contains(libraryWidth), ["idle", "reconnecting"].contains(state) {
                let suffix = scheme == .light ? "light" : "dark"
                let width = libraryWidth == 245 ? "narrow-" : ""
                let active = state == "idle" ? "" : "refreshing-"
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: output.appendingPathComponent("panel-footers-\(active)\(width)\(suffix).png"), options: .atomic)
            }
            XCTAssertFalse(window.isVisible)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func color(at point: NSPoint, hosting: NSView, bitmap: NSBitmapImageRep) throws -> NSColor {
        let x = min(bitmap.pixelsWide - 1, max(0, Int(point.x / hosting.bounds.width * CGFloat(bitmap.pixelsWide))))
        let top = hosting.isFlipped ? point.y : hosting.bounds.height - point.y
        let y = min(bitmap.pixelsHigh - 1, max(0, Int(top / hosting.bounds.height * CGFloat(bitmap.pixelsHigh))))
        return try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    }

    private func distance(_ first: NSColor, _ second: NSColor) -> CGFloat {
        abs(first.redComponent - second.redComponent) + abs(first.greenComponent - second.greenComponent) + abs(first.blueComponent - second.blueComponent)
    }

    private func outputDirectory() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["MACAROK_SNAPSHOT_DIRECTORY"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
private struct FooterGeometryFixture: View {
    @Bindable var model: AppModel
    let libraryWidth: CGFloat
    let playlistWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                LibraryPanelFooter(model: model, summary: .music(albums: 5_464, tracks: 55_562))
                    .frame(width: libraryWidth).background(FooterGeometryProbe(name: "library"))
                PlaylistPanelFooter(model: model)
                    .frame(width: playlistWidth).background(FooterGeometryProbe(name: "playlist"))
            }
            Text("Window status").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 13).frame(height: 29)
                .background(.bar).background(FooterGeometryProbe(name: "status"))
        }
    }
}

@MainActor
private struct FooterGeometryProbe: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> FooterGeometryProbeView {
        let view = FooterGeometryProbeView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }
    func updateNSView(_ nsView: FooterGeometryProbeView, context: Context) {}
}

@MainActor
private final class FooterGeometryProbeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
