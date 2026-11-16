import CoreServices
import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

final class LocalScanChangeCoverageTests: XCTestCase {
    func testFileEventsIgnoreUnrelatedFilesAndBoundAudioAndArtworkChanges() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let album = root.appendingPathComponent("Artist/Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let irrelevant = ["notes.txt", "lyrics.lrc", "booklet.jpg", ".DS_Store"].map { album.appendingPathComponent($0) }
        for url in irrelevant { try Data([1]).write(to: url) }
        let ignored = DirectoryWatcher.changeBatch(paths: irrelevant.map(\.path), flags: irrelevant.map { _ in fileFlag })
        XCTAssertNil(ignored.scanCoverage(root: root))
        let playlist = album.appendingPathComponent("export.m3u")
        XCTAssertEqual(DirectoryWatcher.changeBatch(paths: [playlist.path], flags: [fileFlag]).scanCoverage(root: root),
                       .folders(["Artist/Album"]), "An explicitly opened playlist source must see membership edits.")
        let package = album.appendingPathComponent("Recording.bundle/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let packagedAudio = package.appendingPathComponent("take.wav")
        try Data([1]).write(to: packagedAudio)
        XCTAssertNil(DirectoryWatcher.changeBatch(paths: [packagedAudio.path], flags: [fileFlag]).scanCoverage(root: root))
        let audio = album.appendingPathComponent("Track.FLAC")
        let cover = album.appendingPathComponent("Cover.JPG")
        let batch = DirectoryWatcher.changeBatch(paths: [audio.path, cover.path], flags: [fileFlag, fileFlag])
        XCTAssertEqual(batch.scanCoverage(root: root), .folders(["Artist/Album"]))
        XCTAssertNil(DirectoryChangeBatch(paths: [root.path + "-other/Track.flac"], mustRescan: false).scanCoverage(root: root),
                     "Source containment must use a path boundary.")
    }

    func testDeletedDirectoryFlagsKeepDottedFoldersAndCoalesceAncestorCoverage() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Artist/Old.version", isDirectory: true)
        let renamed = root.appendingPathComponent("Artist/New.version", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: old, to: renamed)
        let directories = DirectoryWatcher.changeBatch(paths: [old.path, renamed.path], flags: [directoryFlag, directoryFlag])
        XCTAssertEqual(directories.scanCoverage(root: root), .folders(["Artist/New.version", "Artist/Old.version"]))
        let unknownDeleted = DirectoryChangeBatch(paths: [root.appendingPathComponent("Artist/Removed.folder").path], mustRescan: false)
        XCTAssertEqual(unknownDeleted.scanCoverage(root: root), .folders(["Artist"]))
        XCTAssertEqual(directories.scanCoverage(root: root)?.merged(with: .folders(["Artist"])), .folders(["Artist"]))
        XCTAssertEqual(LocalScanCoverage.folders(["Artist", "Artist/Album", "ArtistTwo/Album"]).normalized,
                       .folders(["Artist", "ArtistTwo/Album"]))
        XCTAssertEqual(LocalScanCoverage.folders(["Artist"]).merged(with: .all), .all)
        XCTAssertEqual(LocalScanCoverage.folders(["../Other"]).normalized, .all)
    }

    func testDroppedEventsAndRootChangesAlwaysRequestACompleteScan() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(DirectoryChangeBatch(paths: [], mustRescan: false).scanCoverage(root: root), .all)
        XCTAssertEqual(DirectoryChangeBatch(paths: [root.path], mustRescan: false).scanCoverage(root: root), .all)
        let batch = DirectoryWatcher.changeBatch(paths: [root.appendingPathComponent("Album/notes.txt").path],
            flags: [fileFlag | FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)])
        XCTAssertEqual(batch.scanCoverage(root: root), .all)
        let many = (0..<129).map { "Album-\($0)" }
        XCTAssertEqual(LocalScanCoverage.folders(many).normalized, .all)
    }

    private var fileFlag: FSEventStreamEventFlags {
        FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
    }

    private var directoryFlag: FSEventStreamEventFlags {
        FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir)
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokScanCoverage-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
