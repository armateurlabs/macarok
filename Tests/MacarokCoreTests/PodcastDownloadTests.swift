import Foundation
import XCTest
@testable import MacarokCore

final class PodcastDownloadTests: XCTestCase {
    func testDownloadIsExplicitPersistsAcrossReopenAndReusesTheCompletedFile() async throws {
        let fixture = PodcastDownloadFixture()
        defer { fixture.close() }
        let directory = fixture.root.appendingPathComponent("PodcastDownloads")
        let store = PodcastDownloadStore(directory: directory)
        XCTAssertTrue(fixture.requests.isEmpty)
        let initial = try await store.list()
        XCTAssertTrue(initial.isEmpty)
        XCTAssertTrue(fixture.requests.isEmpty, "Opening the library must never download an episode.")
        let track = fixture.track(id: "episode", source: "source-a")
        let download = try await store.download(track: track, transport: fixture.transport)
        let savedFile = await store.file(for: download)
        let file = try XCTUnwrap(savedFile)
        XCTAssertEqual(download.id, PodcastDownloadStore.key(sourceID: track.sourceID, trackID: track.id))
        XCTAssertEqual(download.byteCount, Int64(fixture.payload.count))
        XCTAssertEqual(download.title, track.title)
        XCTAssertEqual(file.pathExtension, "mp3")
        XCTAssertEqual(try Data(contentsOf: file), fixture.payload)
        XCTAssertFalse(try contents(directory).contains { $0.pathExtension == "partial" })

        let reopened = PodcastDownloadStore(directory: directory)
        let restored = try await reopened.list()
        XCTAssertEqual(restored, [download])
        let again = try await reopened.download(track: track, transport: fixture.transport)
        XCTAssertEqual(again, download)
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), fixture.payload)
    }

    func testSourceCopiesHaveDistinctStableFilesAndUnknownExtensionsUseAudio() async throws {
        let fixture = PodcastDownloadFixture()
        defer { fixture.close() }
        let directory = fixture.root.appendingPathComponent("PodcastDownloads")
        let store = PodcastDownloadStore(directory: directory)
        let first = fixture.track(id: "same-remote-id", source: "source-a")
        let second = fixture.track(id: "same-remote-id", source: "source-b")
        let a = try await store.download(track: first, transport: fixture.transport)
        let b = try await store.download(track: second, transport: fixture.transport)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.filename, b.filename)
        XCTAssertEqual(a.filename, "\(PodcastDownloadStore.key(sourceID: first.sourceID, trackID: first.id)).mp3")
        XCTAssertEqual(b.filename, "\(PodcastDownloadStore.key(sourceID: second.sourceID, trackID: second.id)).mp3")
        let unknown = fixture.track(id: "extensionless", source: "source-a", path: "/opaque")
        let fallback = try await store.download(track: unknown, transport: fixture.transport)
        XCTAssertEqual(URL(fileURLWithPath: fallback.filename).pathExtension, "audio")
        let restored = try await PodcastDownloadStore(directory: directory).list()
        XCTAssertEqual(Set(restored.map(\.id)), [a.id, b.id, fallback.id])
    }

    func testFailedAndCancelledTransfersKeepCompletedDownloadsAndCleanStagingFiles() async throws {
        let fixture = PodcastDownloadFixture()
        defer { fixture.close() }
        let directory = fixture.root.appendingPathComponent("PodcastDownloads")
        let store = PodcastDownloadStore(directory: directory)
        let completed = try await store.download(track: fixture.track(id: "kept", source: "source"), transport: fixture.transport)
        let savedFile = await store.file(for: completed)
        let completedFile = try XCTUnwrap(savedFile)
        let original = try Data(contentsOf: completedFile)

        do {
            _ = try await store.download(track: fixture.track(id: "failed", source: "source", path: "/error.mp3"), transport: fixture.transport)
            XCTFail("HTTP failures must not become completed episodes.")
        } catch SourceNetworkError.httpStatus(let status) { XCTAssertEqual(status, 503) }

        let received = expectation(description: "The slow download received audio")
        received.assertForOverFulfill = false
        let slow = fixture.track(id: "cancelled", source: "source", path: "/slow.mp3")
        let transfer = Task { try await store.download(track: slow, transport: fixture.transport, progress: { _, _ in received.fulfill() }) }
        await fulfillment(of: [received], timeout: 5)
        transfer.cancel()
        do { _ = try await transfer.value; XCTFail("A cancelled transfer must not be published.") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }

        let downloads = try await store.list()
        XCTAssertEqual(downloads, [completed])
        XCTAssertEqual(try Data(contentsOf: completedFile), original)
        XCTAssertFalse(try contents(directory).contains { $0.pathExtension == "partial" })
        let reopened = try await PodcastDownloadStore(directory: directory).list()
        XCTAssertEqual(reopened, [completed])
    }

    func testStartupRemovesOnlyOwnedStagingFilesAndNeverExpiresCompletedAudio() async throws {
        let fixture = PodcastDownloadFixture()
        defer { fixture.close() }
        let directory = fixture.root.appendingPathComponent("PodcastDownloads")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let track = fixture.track(id: "old", source: "source")
        let key = PodcastDownloadStore.key(sourceID: track.sourceID, trackID: track.id)
        let completed = PodcastDownload(id: key, sourceID: track.sourceID, trackID: track.id, title: "An old downloaded episode",
                                        filename: "\(key).mp3", byteCount: Int64(fixture.payload.count), downloadedAt: Date(timeIntervalSince1970: 1))
        let completedFile = directory.appendingPathComponent(completed.filename)
        try fixture.payload.write(to: completedFile)
        try JSONEncoder().encode([completed]).write(to: directory.appendingPathComponent("downloads.json"))
        let stale = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        let unowned = [directory.appendingPathComponent(".not-a-download.partial"), directory.appendingPathComponent("notes.partial")]
        for file in [stale] + unowned { try Data("keep or clean by ownership".utf8).write(to: file) }

        let restored = try await PodcastDownloadStore(directory: directory).list()
        XCTAssertEqual(restored, [completed], "Explicit downloads have no automatic age-based expiry.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        for file in unowned { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
        XCTAssertEqual(try Data(contentsOf: completedFile), fixture.payload)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testUnsafeManifestFilenamesCannotResolveOutsideTheDownloadsDirectory() async throws {
        let fixture = PodcastDownloadFixture()
        defer { fixture.close() }
        let directory = fixture.root.appendingPathComponent("PodcastDownloads")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = fixture.root.appendingPathComponent("outside.mp3")
        try fixture.payload.write(to: outside)
        let names = ["../outside.mp3", outside.path, "folder/episode.mp3", "folder\\episode.mp3", ".hidden.mp3", "", ".."]
        let invalid = names.enumerated().map { index, name in
            PodcastDownload(id: "invalid-\(index)", sourceID: "source", trackID: "track-\(index)", title: "Invalid",
                            filename: name, byteCount: 1, downloadedAt: Date())
        }
        let missing = PodcastDownload(id: "missing", sourceID: "source", trackID: "missing", title: "Missing",
                                      filename: "missing.mp3", byteCount: 1, downloadedAt: Date())
        try JSONEncoder().encode(invalid + [missing]).write(to: directory.appendingPathComponent("downloads.json"))
        let store = PodcastDownloadStore(directory: directory)
        let loaded = try await store.list()
        XCTAssertTrue(loaded.isEmpty)
        for record in invalid {
            let file = await store.file(for: record)
            XCTAssertNil(file)
        }
        let sanitized = try JSONDecoder().decode([PodcastDownload].self, from: Data(contentsOf: directory.appendingPathComponent("downloads.json")))
        XCTAssertTrue(sanitized.isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside), fixture.payload)
    }

    func testFileURLsAreNotDownloadedThroughThePodcastTransport() async throws {
        let fixture = PodcastDownloadFixture()
        defer { fixture.close() }
        let store = PodcastDownloadStore(directory: fixture.root.appendingPathComponent("PodcastDownloads"))
        var track = fixture.track(id: "invalid-local", source: "source")
        track.fileURL = fixture.root.appendingPathComponent("private.mp3").absoluteString
        do { _ = try await store.download(track: track, transport: fixture.transport); XCTFail("A podcast download requires an HTTP or HTTPS URL.") }
        catch SourceNetworkError.invalidURL { }
        XCTAssertTrue(fixture.requests.isEmpty)
        let downloads = try await store.list()
        XCTAssertTrue(downloads.isEmpty)
    }

    func testFilesDeletedInFinderCanBeDownloadedAgainAndMissingRecordsArePruned() async throws {
        let fixture = PodcastDownloadFixture()
        defer { fixture.close() }
        let store = PodcastDownloadStore(directory: fixture.root.appendingPathComponent("PodcastDownloads"))
        let track = fixture.track(id: "deleted-outside-app", source: "source")
        let original = try await store.download(track: track, transport: fixture.transport)
        let saved = await store.file(for: original)
        let file = try XCTUnwrap(saved)
        try FileManager.default.removeItem(at: file)
        let replacement = try await store.download(track: track, transport: fixture.transport)
        XCTAssertEqual(replacement.id, original.id)
        XCTAssertEqual(replacement.filename, original.filename)
        XCTAssertEqual(fixture.requests.count, 2, "A stale manifest record must not prevent downloading its missing file again.")
        XCTAssertEqual(try Data(contentsOf: file), fixture.payload)
        try FileManager.default.removeItem(at: file)
        let pruned = try await store.list()
        XCTAssertTrue(pruned.isEmpty)
    }

    func testManifestDirectoriesAndSymlinksAreNeverAdoptedAsCompletedAudio() async throws {
        let fixture = PodcastDownloadFixture()
        defer { fixture.close() }
        let directory = fixture.root.appendingPathComponent("PodcastDownloads")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = fixture.root.appendingPathComponent("outside.mp3")
        try fixture.payload.write(to: outside)
        let link = directory.appendingPathComponent("linked.mp3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.mp3"), withIntermediateDirectories: true)
        let records = ["linked.mp3", "folder.mp3"].enumerated().map { index, name in
            PodcastDownload(id: "not-a-regular-file-\(index)", sourceID: "source", trackID: "track-\(index)", title: "Invalid",
                            filename: name, byteCount: 1, downloadedAt: Date())
        }
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("downloads.json"))
        let store = PodcastDownloadStore(directory: directory)
        let restored = try await store.list()
        XCTAssertTrue(restored.isEmpty)
        for record in records {
            let url = await store.file(for: record)
            XCTAssertNil(url)
        }
        XCTAssertEqual(try Data(contentsOf: outside), fixture.payload)
    }

    func testConcurrentDuplicateRequestsAreRejectedAndCancellationAllowsRetry() async throws {
        let fixture = PodcastDownloadFixture()
        defer { fixture.close() }
        let store = PodcastDownloadStore(directory: fixture.root.appendingPathComponent("PodcastDownloads"))
        let slow = fixture.track(id: "same-episode", source: "source", path: "/slow.mp3")
        let transfer = Task { try await store.download(track: slow, transport: fixture.transport) }
        for _ in 0..<500 where fixture.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(fixture.requests.isEmpty)
        do { _ = try await store.download(track: slow, transport: fixture.transport); XCTFail("The same episode must have only one active transfer.") }
        catch PodcastDownloadError.alreadyDownloading { }
        transfer.cancel()
        do { _ = try await transfer.value; XCTFail("Cancelled transfer unexpectedly completed.") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        let retry = try await store.download(track: fixture.track(id: slow.id, source: slow.sourceID), transport: fixture.transport)
        XCTAssertEqual(retry.id, PodcastDownloadStore.key(sourceID: slow.sourceID, trackID: slow.id))
        let records = try await store.list()
        XCTAssertEqual(records, [retry])
        XCTAssertEqual(fixture.requests.count, 2)
    }

    private func contents(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }
}

private final class PodcastDownloadFixture: @unchecked Sendable {
    let root: URL
    let url: URL
    let transport: SourceTransport
    let payload = Data((0..<256 * 1024).map { UInt8($0 % 251) })
    private let lock = NSLock()
    private var requested: [URLRequest] = []
    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokPodcastDownload-\(UUID().uuidString)")
        let host = "podcast-download-\(UUID().uuidString.lowercased()).invalid"
        url = URL(string: "https://\(host)/episode.mp3")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PodcastDownloadURLProtocol.self]
        transport = SourceTransport(sourceID: host, configuration: configuration)
        PodcastDownloadURLProtocol.register(host, fixture: self)
    }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requested }
    func record(_ request: URLRequest) { lock.lock(); requested.append(request); lock.unlock() }
    func track(id: String, source: String, path: String = "/episode.mp3") -> TrackRecord {
        TrackRecord(id: id, sourceID: source, title: "Synthetic podcast episode", artist: "Macarok", album: "Podcast fixture", duration: 128,
                    fileURL: url.deletingLastPathComponent().appendingPathComponent(String(path.dropFirst())).absoluteString)
    }
    func close() {
        transport.invalidate()
        PodcastDownloadURLProtocol.unregister(url.host!)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class PodcastDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var fixtures: [String: PodcastDownloadFixture] = [:]
    private let queue = DispatchQueue(label: "MacarokTests.PodcastDownloadHTTP")
    private let stateLock = NSLock()
    private var stopped = false
    private var fixture: PodcastDownloadFixture?
    static func register(_ host: String, fixture: PodcastDownloadFixture) { lock.lock(); fixtures[host] = fixture; lock.unlock() }
    static func unregister(_ host: String) { lock.lock(); fixtures[host] = nil; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { lock.lock(); defer { lock.unlock() }; return request.url?.host.flatMap { fixtures[$0] } != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); fixture = request.url?.host.flatMap { Self.fixtures[$0] }; Self.lock.unlock()
        guard let fixture, let url = request.url else { return }
        fixture.record(request)
        let response = HTTPURLResponse(url: url, statusCode: url.path == "/error.mp3" ? 503 : 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "audio/mpeg", "Content-Length": "\(fixture.payload.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        send(offset: 0)
    }
    private func send(offset: Int) {
        queue.asyncAfter(deadline: .now() + (request.url?.path == "/slow.mp3" ? 0.1 : 0.001)) { [weak self] in
            guard let self, let fixture = self.fixture else { return }
            self.stateLock.lock(); let stopped = self.stopped; self.stateLock.unlock()
            guard !stopped else { return }
            let end = min(offset + 16 * 1024, fixture.payload.count)
            self.client?.urlProtocol(self, didLoad: fixture.payload.subdata(in: offset..<end))
            if end < fixture.payload.count { self.send(offset: end) }
            else { self.client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}
