import Foundation
import MacarokCore
import Observation

enum ArchiveTab: String, CaseIterable, Identifiable {
    case browse, saved, recent
    var id: String { rawValue }
    var title: String {
        switch self { case .browse: "Browse"; case .saved: "Saved"; case .recent: "Recent" }
    }
}

enum ArchiveRoute: Hashable {
    case artist(id: String, name: String)
    case shows(artistID: String, artistName: String, year: Int)
    case item(id: String, title: String)

    var title: String {
        switch self {
        case .artist(_, let name): name
        case .shows(_, let name, let year): "\(name) · \(year)"
        case .item(_, let title): title
        }
    }
}

/// Browses Internet Archive collections lazily. Only items the user plays, queues, or saves become library tracks.
@MainActor @Observable
final class InternetArchiveController {
    private weak var model: AppModel?
    private(set) var items: [String: [ArchiveItemRecord]] = [:]
    var tabs: [String: ArchiveTab] = [:]
    var paths: [String: [ArchiveTab: [ArchiveRoute]]] = [:]
    var artistSearch = ""
    var artistSort: ArchiveSort = .popular
    var bookSearch = ""
    var bookLanguage = ""
    var bookSort: ArchiveSort = .popular
    var errorMessage: String?
    private(set) var busyItems: Set<String> = []
    private(set) var artworkPaths: [String: [String: String]] = [:]
    /// Cover thumbnails for items not yet in the library are requested from archive.org.
    var loadsRemoteArtwork = true
    @ObservationIgnored private var lastResume: [String: (trackID: String, position: Double)] = [:]

    init(model: AppModel) { self.model = model }

    func start() async {
        guard let model else { return }
        _ = try? await model.performLibraryWork { try $0.pruneArchiveResponses(olderThan: 30 * 24 * 60 * 60) }
        for source in model.sources where source.kind == .internetArchive { await reload(sourceID: source.id) }
    }

    func reload(sourceID: String) async {
        guard let model else { return }
        do {
            let values = try await model.performLibraryWork { (try $0.archiveItems(sourceID: sourceID), try $0.archiveArtworkPaths(sourceID: sourceID)) }
            items[sourceID] = values.0; artworkPaths[sourceID] = values.1
        } catch { errorMessage = error.localizedDescription }
    }

    func tab(for source: SourceRecord) -> ArchiveTab { tabs[source.id] ?? .browse }
    func path(for source: SourceRecord) -> [ArchiveRoute] { paths[source.id]?[tab(for: source)] ?? [] }
    func push(_ route: ArchiveRoute, source: SourceRecord) { paths[source.id, default: [:]][tab(for: source), default: []].append(route) }
    func pop(source: SourceRecord) { _ = paths[source.id, default: [:]][tab(for: source), default: []].popLast() }
    func popToRoot(source: SourceRecord) { paths[source.id, default: [:]][tab(for: source)] = [] }

    func savedItems(_ source: SourceRecord) -> [ArchiveItemRecord] {
        (items[source.id] ?? []).filter(\.isSaved).sorted { ($0.savedAt ?? .distantPast) > ($1.savedAt ?? .distantPast) }
    }
    func recentItems(_ source: SourceRecord) -> [ArchiveItemRecord] { Array((items[source.id] ?? []).prefix(100)) }
    func record(_ source: SourceRecord, identifier: String) -> ArchiveItemRecord? {
        items[source.id]?.first { $0.identifier == identifier }
    }
    func isBusy(_ identifier: String) -> Bool { busyItems.contains(identifier) }
    func artworkPath(_ source: SourceRecord, identifier: String) -> String? { artworkPaths[source.id]?[identifier] }

    // MARK: Loading

    func client(for source: SourceRecord) -> InternetArchiveClient? {
        guard let model else { return nil }
        return InternetArchiveClient(transport: model.transport(for: source), cache: model.store)
    }

    func search(_ request: ArchiveBrowseRequest, source: SourceRecord, page: Int) async throws -> ArchiveResponse<ArchiveSearchPage> {
        guard let client = client(for: source), let collection = source.archiveCollection else { throw SourceNetworkError.invalidURL }
        return try await Task.detached(priority: .userInitiated) { try await client.search(request, collection: collection, page: page) }.value
    }

    func years(artist: String, source: SourceRecord) async throws -> ArchiveResponse<[ArchiveYearCount]> {
        guard let client = client(for: source) else { throw SourceNetworkError.invalidURL }
        return try await Task.detached(priority: .userInitiated) { try await client.years(artist: artist) }.value
    }

    func item(_ identifier: String, source: SourceRecord) async throws -> ArchiveResponse<ArchiveItem> {
        guard let client = client(for: source) else { throw SourceNetworkError.invalidURL }
        return try await Task.detached(priority: .userInitiated) { try await client.item(identifier: identifier) }.value
    }

    /// Track records for display before an item has been materialized.
    func previewTracks(_ item: ArchiveItem, source: SourceRecord) -> [TrackRecord] {
        guard let model, let collection = source.archiveCollection else { return [] }
        return item.trackRecords(sourceID: source.id, collection: collection, quality: model.settings.archiveQuality)
    }

    // MARK: Library

    /// Writes an item's tracks into the library so the playlist, history, and downloads can address them.
    @discardableResult
    func materialize(_ item: ArchiveItem, source: SourceRecord, saved: Bool? = nil) async throws -> [TrackRecord] {
        guard let model, let collection = source.archiveCollection else { throw SourceNetworkError.invalidURL }
        busyItems.insert(item.identifier); defer { busyItems.remove(item.identifier) }
        let quality = model.settings.archiveQuality
        let firstID = item.trackRecords(sourceID: source.id, collection: collection, quality: quality).first?.id
        var artwork = try? await model.performLibraryWork { store in try firstID.flatMap { try store.track(id: $0)?.artworkPath } }
        if artwork == nil, let data = try? await model.transport(for: source).data(from: InternetArchiveClient.artworkURL(identifier: item.identifier)) {
            artwork = try? await model.cacheArtwork(data, key: StableID.make(source.id, "archive-artwork", item.identifier)).path
        }
        let tracks = item.trackRecords(sourceID: source.id, collection: collection, quality: quality, artworkPath: artwork)
        guard !tracks.isEmpty else { throw ArchiveError.noPlayableAudio(item.identifier) }
        let subtitle = collection == .liveMusic
            ? [item.date, item.recordingSource].compactMap { $0 }.joined(separator: " · ")
            : item.creator
        let record = ArchiveItemRecord(sourceID: source.id, identifier: item.identifier, title: item.albumTitle(for: collection),
                                       creator: item.creator, subtitle: subtitle)
        let ids = tracks.map(\.id)
        let saved = try await model.performLibraryWork { store in
            try store.materializeArchiveItem(record, tracks: tracks, saved: saved)
            return try ids.compactMap { try store.track(id: $0) }
        }
        await reload(sourceID: source.id)
        model.reloadLibrary()
        return saved
    }

    func play(_ item: ArchiveItem, source: SourceRecord, from trackID: String? = nil) async {
        await perform(item, source: source) { [weak self] tracks in
            guard let model = self?.model else { return }
            let start = trackID.flatMap { id in tracks.firstIndex { $0.id == id } } ?? 0
            model.add(Array(tracks[start...]), play: true)
        }
    }

    func add(_ item: ArchiveItem, source: SourceRecord, afterCurrent: Bool = false, trackID: String? = nil) async {
        await perform(item, source: source) { [weak self] tracks in
            guard let model = self?.model else { return }
            let selected = trackID.map { id in tracks.filter { $0.id == id } } ?? tracks
            if afterCurrent { model.addAfterCurrent(selected) } else { model.add(selected, play: model.queue.isEmpty) }
        }
    }

    func setSaved(_ saved: Bool, item: ArchiveItem, source: SourceRecord) async {
        if saved {
            await perform(item, source: source, saved: true) { [weak self] _ in self?.model?.status = "Saved “\(item.title)” to your library." }
            return
        }
        await setSaved(false, identifier: item.identifier, source: source)
    }

    func setSaved(_ saved: Bool, identifier: String, source: SourceRecord) async {
        guard let model else { return }
        do {
            try await model.performLibraryWork { store in
                try store.setArchiveItemSaved(sourceID: source.id, identifier: identifier, saved: saved)
                if !saved { try store.pruneArchiveTracks(sourceID: source.id) }
            }
            await reload(sourceID: source.id)
            model.reloadLibrary()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Downloads one chapter, or the whole item when no track is given.
    func download(_ item: ArchiveItem, source: SourceRecord, trackID: String? = nil) async {
        await perform(item, source: source) { [weak self] tracks in
            guard let downloads = self?.model?.podcastDownloads else { return }
            for track in tracks where trackID == nil || track.id == trackID { downloads.download(track) }
        }
    }

    // MARK: Audiobook resume

    func resumePoint(_ record: ArchiveItemRecord?) -> (trackID: String, position: Double)? {
        guard let record, let trackID = record.resumeTrackID else { return nil }
        return (trackID, record.resumePosition)
    }

    func resume(_ item: ArchiveItem, source: SourceRecord) async {
        let point = resumePoint(record(source, identifier: item.identifier))
        await perform(item, source: source) { [weak self] tracks in
            guard let model = self?.model else { return }
            let start = point.flatMap { point in tracks.firstIndex { $0.id == point.trackID } } ?? 0
            model.playTracks(Array(tracks[start...]), position: point?.position ?? 0)
        }
    }

    /// Called during playback; checkpoints LibriVox listening position per book.
    func recordProgress(track: TrackRecord, position: Double) {
        guard let model, let source = model.sourcesByID[track.sourceID], source.archiveCollection == .librivox,
              let identifier = track.remoteID, position.isFinite else { return }
        if let last = lastResume[identifier], last.trackID == track.id, abs(last.position - position) < 4 { return }
        lastResume[identifier] = (track.id, position)
        Task {
            try? await model.performLibraryWork { try $0.saveArchiveResume(sourceID: source.id, identifier: identifier, trackID: track.id, position: position) }
            if let index = items[source.id]?.firstIndex(where: { $0.identifier == identifier }) {
                items[source.id]?[index].resumeTrackID = track.id
                items[source.id]?[index].resumePosition = position
            }
        }
    }

    private func perform(_ item: ArchiveItem, source: SourceRecord, saved: Bool? = nil,
                         _ action: @escaping @MainActor ([TrackRecord]) -> Void) async {
        errorMessage = nil
        do {
            let tracks = try await materialize(item, source: source, saved: saved)
            action(tracks)
        } catch is CancellationError {
        } catch {
            errorMessage = "Could not open “\(item.title)”: \(error.localizedDescription)"
        }
    }
}
