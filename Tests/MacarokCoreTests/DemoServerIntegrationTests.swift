import XCTest
import Foundation
import Darwin
@testable import MacarokCore

final class DemoServerIntegrationTests: XCTestCase {
    func testDemoServerCleanupIsBoundedAndIdempotent() throws {
        let fixture = try DemoSourceFixture()
        let started = ContinuousClock.now
        fixture.stop()
        fixture.stop()
        XCTAssertLessThan(started.duration(to: .now), .seconds(3))
    }

    func testRealOpenSubsonicAndPodcastRequestsAgainstTheLoopbackDemoServer() async throws {
        let fixture = try DemoSourceFixture()
        defer { fixture.stop() }
        let transport = SourceTransport(sourceID: "demo-server")
        defer { transport.invalidate() }
        let client = OpenSubsonicClient(baseURL: fixture.url, credentials: .init(username: "demo", password: "macarok"), transport: transport)
        let server = try await client.ping()
        XCTAssertEqual(server.serverType, "MacarokDemo")
        let artists = try await client.artists()
        XCTAssertEqual(artists.map(\.name), ["Test Artist"])
        let albums = try await client.albums(artistID: artists[0].id)
        XCTAssertEqual(albums.map(\.title), ["Test Album"])
        let tracks = try await client.fetchLibrary(sourceID: "demo-server")
        XCTAssertEqual(tracks.count, 1, "Symlinks outside the selected folder must not be served.")
        XCTAssertEqual(tracks[0].title, "First")
        XCTAssertEqual(tracks[0].duration, 1)
        XCTAssertEqual(tracks[0].path, "Test Artist/2026 - Test Album/01 - First.wav")
        let record = tracks[0].asTrackRecord(sourceID: "demo-server")
        XCTAssertNil(record.fileURL)
        XCTAssertEqual(record.coverArtID, albums[0].id)

        let folders = try await client.folders()
        XCTAssertEqual(folders.first?.id, "root")
        let directories = try await client.directory(id: "root")
        XCTAssertEqual(directories.first?.title, "Test Artist")
        let albumDirectory = try await client.directory(id: artists[0].id)
        XCTAssertEqual(albumDirectory.first?.id, albums[0].id)
        let songDirectory = try await client.directory(id: albums[0].id)
        XCTAssertEqual(songDirectory.first?.track?.id, tracks[0].id)

        let artwork = try await client.coverArt(id: albums[0].id)
        XCTAssertEqual(artwork.prefix(8), Data([137, 80, 78, 71, 13, 10, 26, 10]))
        let lyrics = try await client.lyrics(songID: tracks[0].id)
        XCTAssertTrue(lyrics?.contains("Instrumental") == true)
        let streamURL = try client.streamURL(songID: tracks[0].id)
        let (range, response) = try await transport.range(from: streamURL, offset: 100, length: 64)
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(range, fixture.audio.subdata(in: 100..<164))

        let apiKeyClient = OpenSubsonicClient(baseURL: fixture.url, credentials: .init(apiKey: "macarok-demo-key"), transport: transport)
        let keyResult = try await apiKeyClient.ping()
        XCTAssertTrue(keyResult.isOpenSubsonic)
        let badClient = OpenSubsonicClient(baseURL: fixture.url, credentials: .init(username: "demo", password: "wrong"), transport: transport)
        do { _ = try await badClient.ping(); XCTFail("Incorrect credentials must be rejected.") }
        catch let error as OpenSubsonicError { XCTAssertEqual(error.code, 40) }

        let podcastTransport = SourceTransport(sourceID: "demo-podcast")
        defer { podcastTransport.invalidate() }
        let feed = try await PodcastClient(transport: podcastTransport).fetchFeed(url: fixture.url.appendingPathComponent("podcast/feed.xml"))
        XCTAssertEqual(feed.title, "Macarok Demo Podcast")
        XCTAssertEqual(feed.episodes.count, 1)
        let episodeRecord = feed.episodes[0].asTrackRecord(sourceID: "demo-podcast", feed: feed)
        XCTAssertNotEqual(episodeRecord.id, record.id)
        let episodeAudio = try await podcastTransport.data(from: feed.episodes[0].audioURL)
        XCTAssertEqual(episodeAudio, fixture.audio)
    }
}

private final class DemoSourceFixture {
    let process: Process
    let directory: URL
    let url: URL
    let audio: Data
    private let terminationSignal: DispatchSemaphore
    private let stopLock = NSLock()
    private var didStop = false

    init() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = repository.appendingPathComponent("scripts/demo-server.py")
        guard FileManager.default.fileExists(atPath: script.path) else { throw XCTSkip("The demo server script is not available.") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokDemoIntegration-\(UUID().uuidString)")
        let library = directory.appendingPathComponent("Music")
        let album = library.appendingPathComponent("Test Artist/2026 - Test Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        var data = Data("RIFF".utf8)
        func u32(_ value: UInt32) -> Data { var value = value.littleEndian; return withUnsafeBytes(of: &value) { Data($0) } }
        func u16(_ value: UInt16) -> Data { var value = value.littleEndian; return withUnsafeBytes(of: &value) { Data($0) } }
        let samples = Data(repeating: 0, count: 16_000)
        data.append(u32(36 + UInt32(samples.count)))
        data.append(Data("WAVEfmt ".utf8)); data.append(u32(16)); data.append(u16(1)); data.append(u16(1))
        data.append(u32(8_000)); data.append(u32(16_000)); data.append(u16(2)); data.append(u16(16))
        data.append(Data("data".utf8)); data.append(u32(UInt32(samples.count))); data.append(samples)
        audio = data
        try audio.write(to: album.appendingPathComponent("01 - First.wav"))
        let outside = directory.appendingPathComponent("outside.mp3")
        try Data("Not library content".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("escape.mp3"), withDestinationURL: outside)

        let ready = directory.appendingPathComponent("ready.json")
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, library.path, "--port", "0", "--ready-file", ready.path]
        process.standardOutput = Pipe(); process.standardError = Pipe()
        let signal = DispatchSemaphore(value: 0)
        terminationSignal = signal
        process.terminationHandler = { _ in signal.signal() }
        do { try process.run() }
        catch {
            Self.terminate(process, signal: signal)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        var details: [String: Any]?
        for _ in 0..<150 {
            if let data = try? Data(contentsOf: ready), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { details = value; break }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let address = details?["url"] as? String, let url = URL(string: address) else {
            Self.terminate(process, signal: signal)
            try? FileManager.default.removeItem(at: directory)
            throw XCTSkip("Python 3 is required for the loopback source integration fixture.")
        }
        self.url = url
    }

    func stop() {
        stopLock.lock()
        guard !didStop else { stopLock.unlock(); return }
        didStop = true
        stopLock.unlock()
        Self.terminate(process, signal: terminationSignal)
    }

    private static func terminate(_ process: Process, signal: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if signal.wait(timeout: .now() + 1) == .timedOut {
            if process.isRunning, process.processIdentifier > 0 { kill(process.processIdentifier, SIGKILL) }
            _ = signal.wait(timeout: .now() + 1)
        }
    }

    deinit { stop(); try? FileManager.default.removeItem(at: directory) }
}
