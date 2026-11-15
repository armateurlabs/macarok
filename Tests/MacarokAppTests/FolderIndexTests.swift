import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

final class FolderIndexTests: XCTestCase {
    func testFolderTreePreservesRootNestedPathsAndPrefixSiblings() throws {
        let tracks = [
            remoteTrack("root", path: "song.flac"),
            remoteTrack("live-1", path: "Rock/Live/01.flac"),
            remoteTrack("live-2", path: "Rock/./Live/02.flac"),
            remoteTrack("studio", path: "Rock\\Studio\\03.flac"),
            remoteTrack("sibling", path: "Rockabilly/04.flac")
        ]
        let nodes = try LibraryFolderIndex.build(tracks: tracks, sources: [], rootName: "Navidrome")
        let root = try XCTUnwrap(nodes.first)
        XCTAssertEqual(root.id, "")
        XCTAssertEqual(root.name, "Navidrome")
        XCTAssertEqual(root.children?.map(\.name), ["Rock", "Rockabilly"])
        XCTAssertEqual(root.children?.first?.children?.map(\.id), ["Rock/Live", "Rock/Studio"])
        XCTAssertEqual(allIDs(nodes), ["", "Rock", "Rock/Live", "Rock/Studio", "Rockabilly"])
        XCTAssertNil(root.children?.last?.children)
    }

    func testSourceRootsAreResolvedOnceForRepeatedLocalTrackPaths() {
        let folder = SourceRecord(id: "folder", kind: .local, name: "Music", location: "file:///Music")
        let playlist = SourceRecord(id: "playlist", kind: .local, name: "Playlist", location: "file:///Imports/list.m3u8")
        let server = SourceRecord(id: "server", kind: .openSubsonic, name: "Server", location: "https://music.invalid")
        var filesystemReads = 0
        let resolver = LibraryFolderPathResolver(sources: [folder, playlist, server], isDirectory: { url in
            filesystemReads += 1
            return url.path == "/Music"
        })
        let local = TrackRecord(id: "local", sourceID: folder.id, fileURL: "file:///Music/Rock/Live/01.flac")
        for _ in 0..<100 { XCTAssertEqual(resolver.folderPath(local), "Rock/Live") }
        XCTAssertEqual(resolver.folderPath(TrackRecord(sourceID: folder.id, fileURL: "file:///Music/root.flac")), "")
        XCTAssertEqual(resolver.folderPath(TrackRecord(sourceID: playlist.id, fileURL: "file:///Imports/Album/01.flac")), "Album")
        XCTAssertEqual(resolver.folderPath(TrackRecord(sourceID: playlist.id, fileURL: "file:///Elsewhere/Album/01.flac")), "Elsewhere/Album")
        XCTAssertEqual(resolver.folderPath(TrackRecord(sourceID: "unknown", fileURL: "file:///Elsewhere/Album/01.flac")), "Album")
        XCTAssertEqual(filesystemReads, 2, "Filesystem checks belong to local sources, never individual tracks or a remote server.")
    }

    func testLargeCatalogBuildsWithoutRescanningAllTracksForEveryFolder() throws {
        let tracks = (0..<30_000).map { index in
            remoteTrack(String(index), path: "Artist \(index % 1_000)/Album \(index % 6_000)/\(index).flac")
        }
        let started = Date()
        let nodes = try LibraryFolderIndex.build(tracks: tracks, sources: [], rootName: "Large Library")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(nodes.first?.children?.count, 1_000)
        XCTAssertEqual(allIDs(nodes).count, 7_001)
        XCTAssertLessThan(elapsed, 10, "A 30,000-track catalog with 7,000 folders must not trigger a catalog scan per folder.")
        print("Built folder index for 30,000 tracks and 7,000 folders in \(String(format: "%.3f", elapsed)) seconds.")
    }

    func testCancelledSnapshotDoesNotContinueBuildingTheTree() async throws {
        let gate = FolderBuildGate()
        let tracks = (0..<20_000).map { remoteTrack(String($0), path: "Artist/Album \($0)/track.flac") }
        let task = Task.detached {
            await gate.wait()
            return try LibraryFolderIndex.build(tracks: tracks, sources: [], rootName: "Cancelled")
        }
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("A cancelled folder snapshot must not publish a tree.") }
        catch is CancellationError { }
    }

    private func remoteTrack(_ id: String, path: String) -> TrackRecord {
        TrackRecord(id: id, sourceID: "server", remoteID: id, remotePath: path, format: "FLAC")
    }

    private func allIDs(_ roots: [FolderNode]) -> Set<String> {
        var pending = roots
        var ids = Set<String>()
        while let node = pending.popLast() {
            ids.insert(node.id)
            pending.append(contentsOf: node.children ?? [])
        }
        return ids
    }
}

private actor FolderBuildGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if !isOpen { await withCheckedContinuation { continuation = $0 } }
    }
    func open() { isOpen = true; continuation?.resume(); continuation = nil }
}
