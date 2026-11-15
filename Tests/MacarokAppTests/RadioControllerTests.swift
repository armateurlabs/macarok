import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

@MainActor
final class RadioControllerTests: XCTestCase {
    func testNewSearchAndExplicitCancellationRejectLateDirectoryResponses() async throws {
        let script = RadioDirectoryScript()
        let fixture = try await makeFixture(script: script)
        defer { fixture.cleanup(); Task { await script.finishAll() } }
        let controller = fixture.controller
        let oldStation = station("Old Search", directoryID: "00000000-0000-0000-0000-000000000001")
        let newStation = station("New Search", directoryID: "00000000-0000-0000-0000-000000000002")
        controller.query = "old"
        let oldSearch = Task { await controller.search() }
        try await requireRequests(script, count: 1)
        XCTAssertTrue(controller.isSearching)

        controller.query = "new"
        let newSearch = Task { await controller.search() }
        try await requireRequests(script, count: 2)
        await script.respond(to: 1, data: try directoryData([newStation]))
        await newSearch.value
        XCTAssertEqual(controller.results.map(\.id), [newStation.id])
        XCTAssertFalse(controller.isSearching)

        // The injected transport deliberately ignores task cancellation until its reply is released.
        await script.respond(to: 0, data: try directoryData([oldStation]))
        await oldSearch.value
        XCTAssertEqual(controller.results.map(\.id), [newStation.id])
        XCTAssertFalse(controller.isSearching)
        XCTAssertNil(controller.errorMessage)

        controller.query = "cancelled"
        let cancelledSearch = Task { await controller.search() }
        try await requireRequests(script, count: 3)
        controller.cancelSearch()
        XCTAssertFalse(controller.isSearching)
        await script.respond(to: 2, data: try directoryData([oldStation]))
        await cancelledSearch.value
        XCTAssertEqual(controller.results.map(\.id), [newStation.id])
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(try fixture.store.radioStations().isEmpty)
        XCTAssertEqual(try fixture.store.sources().map(\.id), [fixture.musicSource.id])
    }

    func testBrowsingPersistsOnlyQueuedOrSavedStationsAndKeepsFavoriteResultsSynchronized() async throws {
        let script = RadioDirectoryScript()
        let fixture = try await makeFixture(script: script)
        defer { fixture.cleanup(); Task { await script.finishAll() } }
        let controller = fixture.controller
        let favorite = station("Favorite", directoryID: "00000000-0000-0000-0000-000000000011")
        let queued = station("Queued", directoryID: "00000000-0000-0000-0000-000000000012")
        let untouched = station("Untouched", directoryID: "00000000-0000-0000-0000-000000000013")
        controller.query = "stations"
        controller.country = "France"
        controller.language = "English"
        controller.tags = "jazz"
        let search = Task { await controller.search() }
        try await requireRequests(script, count: 1)
        await script.respond(to: 0, data: try directoryData([favorite, queued, untouched]))
        await search.value

        XCTAssertEqual(controller.results.count, 3)
        XCTAssertTrue(controller.results.allSatisfy { !$0.isFavorite })
        XCTAssertTrue(controller.stations.isEmpty)
        XCTAssertTrue(try fixture.store.radioStations().isEmpty, "Directory results are not an imported station catalog.")
        XCTAssertTrue(fixture.model.queue.isEmpty)
        XCTAssertFalse(try fixture.store.sources().contains { $0.kind == .radio })
        let capturedRequest = await script.request(at: 0)
        let request = try XCTUnwrap(capturedRequest)
        let parameters = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(parameters.first { $0.name == "country" }?.value, "France")
        XCTAssertEqual(parameters.first { $0.name == "language" }?.value, "English")
        XCTAssertEqual(parameters.first { $0.name == "tagList" }?.value, "jazz")

        await controller.addToPlaylist(queued)
        await fixture.model.flushQueue()
        XCTAssertEqual(controller.stations.map(\.id), [queued.id])
        XCTAssertEqual(try fixture.store.radioStation(id: queued.id)?.isFavorite, false)
        XCTAssertEqual(fixture.model.queue.map(\.track.id), [queued.id])
        XCTAssertEqual(try fixture.store.loadQueue()?.trackIDs, [queued.id])
        XCTAssertNil(fixture.model.currentQueueID, "Explicit Add remains passive even for an empty queue.")
        XCTAssertEqual(fixture.model.player.state, .stopped)

        await controller.saveFavorite(favorite)
        XCTAssertEqual(controller.results.first { $0.id == favorite.id }?.isFavorite, true)
        XCTAssertEqual(try fixture.store.radioStation(id: favorite.id)?.isFavorite, true)
        XCTAssertEqual(Set(try fixture.store.radioStations().map(\.id)), [favorite.id, queued.id])
        XCTAssertNil(try fixture.store.radioStation(id: untouched.id))
        XCTAssertEqual(fixture.model.queue.map(\.track.id), [queued.id])

        await controller.removeFavorite(favorite)
        XCTAssertEqual(controller.results.first { $0.id == favorite.id }?.isFavorite, false)
        XCTAssertEqual(try fixture.store.radioStation(id: favorite.id)?.isFavorite, false)
        XCTAssertNotNil(try fixture.store.track(id: favorite.id), "Unfavoriting retains the saved station and any stable references.")
        try fixture.store.saveRadioStation(favorite, favorite: true)
        await controller.reload()
        XCTAssertEqual(controller.results.first { $0.id == favorite.id }?.isFavorite, true, "Reload must synchronize cached search rows with persisted favorites.")
        XCTAssertEqual(fixture.model.queue.map(\.track.id), [queued.id])
        XCTAssertNil(controller.errorMessage)
    }

    func testAllSourcesSurvivesFavoriteURLAndPlaylistActionsWithoutReplacingCurrentEntry() async throws {
        let script = RadioDirectoryScript()
        let fixture = try await makeFixture(script: script)
        defer { fixture.cleanup(); Task { await script.finishAll() } }
        let model = fixture.model
        model.libraryScope = .all
        await model.waitForLibraryLoad()
        model.add([fixture.musicTrack, fixture.musicTrack])
        let original = model.queue
        model.currentQueueID = original[0].id
        model.selectedQueueID = original[1].id
        model.restorePosition = 12.5
        let favorite = station("Favorite", directoryID: "00000000-0000-0000-0000-000000000021")

        await fixture.controller.saveFavorite(favorite)
        XCTAssertEqual(model.libraryScope, .all)
        await fixture.controller.addURL(name: "Manual Station", address: "https://radio.invalid/manual.aac")
        XCTAssertEqual(model.libraryScope, .all)
        await fixture.controller.addToPlaylist(favorite, afterCurrent: true)
        await fixture.controller.addToPlaylist(favorite)
        await model.waitForLibraryLoad()
        await model.flushQueue()

        XCTAssertEqual(model.libraryScope, .all)
        XCTAssertEqual(model.queue.map(\.track.id), [fixture.musicTrack.id, favorite.id, fixture.musicTrack.id, favorite.id])
        XCTAssertEqual(model.queue[0].id, original[0].id)
        XCTAssertEqual(model.queue[2].id, original[1].id)
        XCTAssertNotEqual(model.queue[1].id, model.queue[3].id)
        XCTAssertEqual(model.currentQueueID, original[0].id)
        XCTAssertEqual(model.selectedQueueID, original[1].id)
        XCTAssertEqual(model.restorePosition, 12.5)
        XCTAssertEqual(model.player.state, .stopped)
        XCTAssertEqual(model.albums.count, 1, "Station persistence must not turn radio into music albums.")
        XCTAssertEqual(Set(model.radioStations.map(\.id)), Set(fixture.controller.stations.map(\.id)))
        XCTAssertEqual(try fixture.store.loadQueue()?.trackIDs, model.queue.map(\.track.id))
        XCTAssertNil(fixture.controller.errorMessage)
        let directoryRequests = await script.requestCount
        XCTAssertEqual(directoryRequests, 0, "Adding direct station URLs must not query the directory.")
    }

    func testFavoriteRefreshPreservesActualStoredIdentityAndOriginWhileUpdatingMetadata() async throws {
        let script = RadioDirectoryScript()
        let fixture = try await makeFixture(script: script)
        defer { fixture.cleanup(); Task { await script.finishAll() } }
        let directoryID = "00000000-0000-0000-0000-000000000031"
        var saved = station("Old Name", directoryID: directoryID)
        saved.id = "existing-station-reference"
        saved.sourceID = "existing-radio-origin"
        let notFavorite = station("Not Favorite", directoryID: "00000000-0000-0000-0000-000000000032")
        let manual = RadioStationRecord(name: "Manual Favorite", streamURL: "https://radio.invalid/manual")
        try fixture.store.saveRadioStation(saved, favorite: true)
        try fixture.store.saveRadioStation(notFavorite, favorite: false)
        try fixture.store.saveRadioStation(manual, favorite: true)
        try fixture.store.saveQueue(trackIDs: [saved.id, saved.id], currentIndex: 1, position: 0)
        let playlist = try fixture.store.savePlaylist(name: "Stable Radio References", trackIDs: [saved.id])
        var latest = station("Renamed by Directory", directoryID: directoryID)
        latest.resolvedURL = "https://cdn.invalid/new.aac"
        latest.artworkURL = "https://artwork.invalid/new.png"
        latest.country = "New Country"
        latest.codec = "AAC"
        latest.bitrate = 256
        let refresh = Task { try await fixture.controller.refreshFavorites() }
        try await requireRequests(script, count: 1)
        let capturedRequest = await script.request(at: 0)
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/json/stations/byuuid/\(directoryID)")
        await script.respond(to: 0, data: try directoryData([latest]))
        try await refresh.value

        let updated = try XCTUnwrap(fixture.store.radioStation(id: saved.id))
        XCTAssertEqual(updated.id, saved.id)
        XCTAssertEqual(updated.sourceID, saved.sourceID)
        XCTAssertEqual(updated.directoryID, directoryID)
        XCTAssertTrue(updated.isFavorite)
        XCTAssertEqual(updated.name, latest.name)
        XCTAssertEqual(updated.resolvedURL, latest.resolvedURL)
        XCTAssertEqual(updated.artworkURL, latest.artworkURL)
        XCTAssertEqual(updated.country, latest.country)
        XCTAssertEqual(updated.codec, latest.codec)
        XCTAssertEqual(updated.bitrate, latest.bitrate)
        XCTAssertEqual(try fixture.store.track(id: saved.id)?.sourceID, saved.sourceID)
        XCTAssertEqual(try fixture.store.track(id: saved.id)?.title, latest.title)
        XCTAssertNil(try fixture.store.radioStation(id: latest.id), "The directory's derived identity must not create a second copy.")
        XCTAssertEqual(try fixture.store.loadQueue()?.trackIDs, [saved.id, saved.id])
        XCTAssertEqual(try fixture.store.playlistTracks(id: playlist.id).map(\.id), [saved.id])
        XCTAssertEqual(fixture.controller.stations.first { $0.id == saved.id }, updated)
        let directoryRequests = await script.requestCount
        XCTAssertEqual(directoryRequests, 1, "Only saved directory favorites should be refreshed.")
        XCTAssertNil(fixture.controller.errorMessage)
    }

    func testUnsupportedOrInvalidStationsDoNotCreateSourcesOrQueueEntries() async throws {
        let script = RadioDirectoryScript()
        let fixture = try await makeFixture(script: script)
        defer { fixture.cleanup(); Task { await script.finishAll() } }
        var hls = station("HLS", directoryID: "00000000-0000-0000-0000-000000000041")
        hls.isHLS = true
        await fixture.controller.addToPlaylist(hls)
        XCTAssertEqual(fixture.controller.errorMessage, RadioError.unsupportedHLS.localizedDescription)
        await fixture.controller.addURL(name: "Invalid", address: "file:///private/station.mp3")
        XCTAssertEqual(fixture.controller.errorMessage, RadioError.invalidURL.localizedDescription)
        await fixture.controller.addURL(name: "HLS URL", address: "https://radio.invalid/live.m3u8")
        XCTAssertEqual(fixture.controller.errorMessage, RadioError.unsupportedHLS.localizedDescription)
        XCTAssertTrue(fixture.model.queue.isEmpty)
        XCTAssertTrue(try fixture.store.radioStations().isEmpty)
        XCTAssertFalse(try fixture.store.sources().contains { $0.kind == .radio })
        let directoryRequests = await script.requestCount
        XCTAssertEqual(directoryRequests, 0)

        await fixture.controller.addURL(name: "Valid", address: "https://radio.invalid/live.mp3")
        XCTAssertNil(fixture.controller.errorMessage, "A successful retry must clear an earlier validation failure.")
        XCTAssertEqual(try fixture.store.radioStations().count, 1)
        XCTAssertTrue(fixture.model.queue.isEmpty)
    }

    func testObsoleteRefreshCannotRecreateARemovedRadioSourceOrOverwriteItsReplacement() async throws {
        let script = RadioDirectoryScript()
        let fixture = try await makeFixture(script: script)
        defer { fixture.cleanup() }
        let saved = station("Original", directoryID: "00000000-0000-0000-0000-000000000051")
        try fixture.store.saveRadioStation(saved, favorite: true)
        let worker = LibraryBackgroundWorker(), oldGeneration = UUID(), newGeneration = UUID()
        try await worker.beginRefresh(store: fixture.store, sourceID: saved.sourceID, generation: oldGeneration, incompleteKey: nil)
        try await worker.deleteSource(store: fixture.store, sourceID: saved.sourceID, incompleteKey: "radio-test")
        do {
            try await worker.updateRadioStation(store: fixture.store, station: saved, generation: oldGeneration)
            XCTFail("A removed radio source must not be recreated by a stale refresh.")
        } catch is CancellationError { }
        XCTAssertNil(try fixture.store.radioStation(id: saved.id))
        var replacement = saved; replacement.name = "Replacement"
        try fixture.store.saveRadioStation(replacement, favorite: true)
        try await worker.beginRefresh(store: fixture.store, sourceID: saved.sourceID, generation: newGeneration, incompleteKey: nil)
        do {
            try await worker.updateRadioStation(store: fixture.store, station: saved, generation: oldGeneration)
            XCTFail("A previous generation must not overwrite the new source.")
        } catch is CancellationError { }
        XCTAssertEqual(try fixture.store.radioStation(id: saved.id)?.name, "Replacement")
        replacement.name = "Current Refresh"
        try await worker.updateRadioStation(store: fixture.store, station: replacement, generation: newGeneration)
        XCTAssertEqual(try fixture.store.radioStation(id: saved.id)?.name, "Current Refresh")
    }

    private func makeFixture(script: RadioDirectoryScript) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokRadioController-\(UUID().uuidString)")
        let store = try LibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let source = SourceRecord(id: "radio-test-music", kind: .local, name: "Music", location: directory.absoluteString)
        let track = TrackRecord(id: "radio-test-song", sourceID: source.id, title: "Song", artist: "Artist", album: "Album", duration: 120)
        try store.saveSource(source)
        try store.upsertTracks([track])
        let model = AppModel(store: store, preferences: AppPreferences(), registerSystemControls: false)
        await model.start()
        let client = RadioBrowserClient(mirrors: [URL(string: "https://directory.invalid")!], transport: { request in try await script.send(request) })
        let controller = RadioController(model: model, directory: client)
        model.radio = controller
        await controller.reload()
        return Fixture(directory: directory, store: store, model: model, controller: controller, musicSource: source, musicTrack: track)
    }

    private func station(_ name: String, directoryID: String) -> RadioStationRecord {
        RadioStationRecord(name: name, streamURL: "https://radio.invalid/\(directoryID).mp3", directoryID: directoryID,
                           country: "France", language: "English", tags: "jazz", codec: "MP3", bitrate: 192)
    }

    private func directoryData(_ stations: [RadioStationRecord]) throws -> Data {
        let rows = stations.map { station -> [String: Any] in
            var row: [String: Any] = ["stationuuid": station.directoryID!, "name": station.name, "url": station.streamURL,
                                      "country": station.country, "language": station.language, "tags": station.tags,
                                      "codec": station.codec, "bitrate": station.bitrate, "hls": station.isHLS ? 1 : 0]
            if let value = station.resolvedURL { row["url_resolved"] = value }
            if let value = station.artworkURL { row["favicon"] = value }
            return row
        }
        return try JSONSerialization.data(withJSONObject: rows)
    }

    private func requireRequests(_ script: RadioDirectoryScript, count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await script.requestCount >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The radio directory request did not start.")
        throw URLError(.timedOut)
    }

    private struct Fixture {
        let directory: URL
        let store: LibraryStore
        let model: AppModel
        let controller: RadioController
        let musicSource: SourceRecord
        let musicTrack: TrackRecord
        @MainActor func cleanup() {
            controller.cancelSearch()
            model.cancelRefresh()
            model.stopPlayback(clearCurrent: true)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// Responses remain gated even after cancellation, exercising late transport completion at the controller boundary.
private actor RadioDirectoryScript {
    private var requests: [URLRequest] = []
    private var pending: [Int: CheckedContinuation<(Data, HTTPURLResponse), Error>] = [:]
    var requestCount: Int { requests.count }

    func request(at index: Int) -> URLRequest? { requests.indices.contains(index) ? requests[index] : nil }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func respond(to index: Int, data: Data) {
        guard requests.indices.contains(index), let continuation = pending.removeValue(forKey: index), let url = requests[index].url else { return }
        continuation.resume(returning: (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!))
    }

    func finishAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}
