import Foundation
import Observation
import MacarokCore

@MainActor @Observable
final class RadioController {
    private weak var model: AppModel?
    @ObservationIgnored private let directory: RadioBrowserClient
    @ObservationIgnored private var searchTask: Task<[RadioStationRecord], Error>?
    @ObservationIgnored private var searchID = UUID()
    var query = ""
    var country = ""
    var language = ""
    var tags = ""
    private(set) var results: [RadioStationRecord] = []
    private(set) var stations: [RadioStationRecord] = []
    private(set) var isSearching = false
    var errorMessage: String?

    init(model: AppModel, directory: RadioBrowserClient = RadioBrowserClient()) {
        self.model = model; self.directory = directory
    }

    func reload() async {
        guard let model else { return }
        do { stations = try await model.performLibraryWork { try $0.radioStations() }; updateFavoriteResults() }
        catch { errorMessage = error.localizedDescription }
    }

    func cancelSearch() { searchTask?.cancel(); searchTask = nil; searchID = UUID(); isSearching = false }

    func search() async {
        cancelSearch()
        let id = UUID(); searchID = id; isSearching = true; errorMessage = nil
        let directory = directory, query = query, country = country, language = language, tags = tags
        let task = Task { try await directory.search(query: query, country: country, language: language, tags: tags) }
        searchTask = task
        do {
            let values = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard searchID == id, !Task.isCancelled else { return }
            results = values; updateFavoriteResults()
        } catch {
            if searchID == id, !Task.isCancelled { errorMessage = error.localizedDescription }
        }
        if searchID == id { isSearching = false; searchTask = nil }
    }

    func saveFavorite(_ station: RadioStationRecord) async {
        await persist(station, favorite: true, selectSource: true)
    }

    func removeFavorite(_ station: RadioStationRecord) async {
        await persist(station, favorite: false, selectSource: false)
    }

    func addToPlaylist(_ station: RadioStationRecord, playNow: Bool = false, afterCurrent: Bool = false) async {
        guard !station.isHLS else { errorMessage = RadioError.unsupportedHLS.localizedDescription; return }
        guard await persist(station, favorite: nil, selectSource: false), let model else { return }
        let track = stations.first(where: { $0.id == station.id })?.track ?? station.track
        if afterCurrent { model.addAfterCurrent([track]) }
        else { model.add([track], play: playNow) }
    }

    func addURL(name: String, address: String, favorite: Bool = true, playNow: Bool = false) async {
        do {
            let url = try RadioError.validatedURL(address)
            guard url.pathExtension.lowercased() != "m3u8" else { throw RadioError.unsupportedHLS }
            let value = RadioStationRecord(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url.host ?? "Radio Station" : name.trimmingCharacters(in: .whitespacesAndNewlines), streamURL: url.absoluteString)
            if await persist(value, favorite: favorite, selectSource: true), playNow { await addToPlaylist(value, playNow: true) }
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult private func persist(_ station: RadioStationRecord, favorite: Bool?, selectSource: Bool) async -> Bool {
        guard let model else { return false }
        errorMessage = nil
        do {
            let values = try await model.performLibraryWork { store in
                try store.saveRadioStation(station, favorite: favorite)
                return (try store.sources(), try store.radioStations())
            }
            model.sources = values.0; stations = values.1; updateFavoriteResults()
            if selectSource, !model.isAllSources { model.sourceID = station.sourceID }
            await model.patchRadioStations(values.1.map(\.track))
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    private func updateFavoriteResults() {
        let favorites = Set(stations.filter(\.isFavorite).map(\.id))
        for index in results.indices { results[index].isFavorite = favorites.contains(results[index].id) }
    }

    /// Refreshes saved directory entries without downloading the directory or opening streams.
    func refreshFavorites(commit: (@Sendable (RadioStationRecord) async throws -> Void)? = nil) async throws {
        guard let model else { return }
        let saved = try await model.performLibraryWork { try $0.radioStations() }
        for station in saved where station.isFavorite && station.directoryID != nil {
            try Task.checkCancellation()
            if var latest = try await directory.station(directoryID: station.directoryID!) {
                latest.id = station.id; latest.sourceID = station.sourceID
                let value = latest
                try Task.checkCancellation()
                if let commit { try await commit(value) }
                else {
                    try await model.performLibraryWork { store in
                        guard try store.sources().contains(where: { $0.id == value.sourceID && $0.kind == .radio }) else { throw CancellationError() }
                        try store.saveRadioStation(value, favorite: true)
                    }
                }
            }
        }
        await reload()
    }
}
