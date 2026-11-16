import Foundation
import MacarokCore
import Observation

enum SimilarMixFollow: String, Codable, CaseIterable, Identifiable {
    case seed, lastPlayed, blend
    var id: Self { self }
    var title: String {
        switch self {
        case .seed: "Seed"
        case .lastPlayed: "Last Played"
        case .blend: "Blend"
        }
    }
    var longTitle: String {
        switch self {
        case .seed: "The seed"
        case .lastPlayed: "The last played track"
        case .blend: "Both (blend)"
        }
    }
}

struct SimilarityRequest: Identifiable {
    let id = UUID()
    var seed: [TrackRecord]
    var dynamic: Bool
}

/// A dynamic mix: only the next track is chosen. Skipped recordings never return during the session.
struct SimilarMixSession {
    let id = UUID()
    /// Tracks queried when the mix follows its seed.
    var seed: [TrackRecord]
    var title: String
    var subtitle: String
    var played: [TrackRecord] = []
    /// Track identifiers and edition keys.
    var skipped: Set<String> = []
    var skippedCount = 0
    var suggestionID: UUID?
    var suggestionTrack: TrackRecord?
    /// The track the suggestion was chosen from, for display.
    var suggestionReason = ""
    /// Queue entries created by this mix; the session ends when none remain.
    var entryIDs: Set<UUID> = []
}

@MainActor @Observable
final class SimilarityController {
    @ObservationIgnored weak var model: AppModel?
    private(set) var session: SimilarMixSession?
    private(set) var isSearching = false
    private(set) var isGenerating = false
    var request: SimilarityRequest?
    /// The latest failure, shown in the mix banner or the sheet.
    var error: String?

    @ObservationIgnored var serviceOverride: SimilarityService?
    @ObservationIgnored var libraryOverride: SimilarityLibrary?
    @ObservationIgnored var chooseNext: ([SimilarityCandidate], TrackRecord?) -> TrackRecord? = { candidates, previous in
        var generator = SystemRandomNumberGenerator()
        return SimilarityRanking.next(candidates, avoidingArtistOf: previous, using: &generator)
    }
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var playsWhenReady = false
    @ObservationIgnored private var editingQueue = false
    @ObservationIgnored private var sessionLibrary: SimilarityLibrary?
    @ObservationIgnored private let listenBrainz = ListenBrainzClient()

    var isMixing: Bool { session != nil }
    var lastFMAvailable: Bool { model?.scrobbling?.similarityClient != nil }
    func isSuggestion(_ id: UUID) -> Bool { session?.suggestionID == id }

    // MARK: Dynamic mix

    func startMix(_ seed: [TrackRecord]) {
        guard let model else { return }
        let available = seed.filter(\.isAvailable)
        guard let start = Self.startTrack(available) else {
            model.fail("Tracks unavailable", "Reconnect the source and refresh its library before starting a mix."); return
        }
        end()
        error = nil
        let ids = model.replaceQueue(with: [start], name: "Start Similar Mix", play: true)
        guard !ids.isEmpty else { return }
        let (title, subtitle) = Self.describe(available)
        session = SimilarMixSession(seed: Self.queryTracks(available), title: title, subtitle: subtitle,
                                    played: [start], entryIDs: Set(ids))
        model.status = "Started a similar mix from “\(title)”."
        requestSuggestion()
    }

    func end(removingSuggestion: Bool = true) {
        searchTask?.cancel(); searchTask = nil
        isSearching = false; playsWhenReady = false; sessionLibrary = nil
        if removingSuggestion, let id = session?.suggestionID { removeQuietly(id) }
        session = nil
    }

    func skipSuggestion() {
        guard var session, let id = session.suggestionID, let track = session.suggestionTrack else { return }
        session.skipped.formUnion([track.id, SimilarityLibrary.editionKey(track)]); session.skippedCount += 1
        session.suggestionID = nil; session.suggestionTrack = nil
        self.session = session
        removeQuietly(id)
        requestSuggestion()
    }

    func restoreSkipped() {
        session?.skipped = []; session?.skippedCount = 0
    }

    func followChanged() {
        guard let id = session?.suggestionID else { if isMixing { requestSuggestion() }; return }
        session?.suggestionID = nil; session?.suggestionTrack = nil
        removeQuietly(id)
        requestSuggestion()
    }

    func retry() { error = nil; requestSuggestion() }

    /// Next counts as a skip during a mix, and repeat modes do not apply. Returns false outside a mix.
    func handleAdvance(manual: Bool) -> Bool {
        guard var session, let model else { return false }
        if manual, let track = model.currentTrack {
            session.skipped.formUnion([track.id, SimilarityLibrary.editionKey(track)]); session.skippedCount += 1
            self.session = session
        }
        if let index = model.currentIndex, index + 1 < model.queue.count {
            model.playQueueItem(model.queue[index + 1].id, origin: manual ? .manual : .automatic)
        } else {
            // The next track is still being chosen; it starts as soon as it is found.
            model.stopPlayback(clearCurrent: false)
            playsWhenReady = true
            if !isSearching { requestSuggestion() }
        }
        return true
    }

    func currentEntryChanged() {
        guard isMixing else { return }
        // Queue edits wait for the caller that changed the current entry to finish.
        Task { @MainActor [weak self] in self?.reconcileCurrentEntry() }
    }

    func queueChanged() {
        guard !editingQueue, var session, let model else { return }
        let ids = Set(model.queue.map(\.id))
        if session.entryIDs.isDisjoint(with: ids) { end(removingSuggestion: false); return }
        if let id = session.suggestionID, !ids.contains(id) {
            // Removing the announced track counts as skipping it.
            if let track = session.suggestionTrack {
                session.skipped.formUnion([track.id, SimilarityLibrary.editionKey(track)]); session.skippedCount += 1
            }
            session.suggestionID = nil; session.suggestionTrack = nil
            self.session = session
            requestSuggestion()
        }
    }

    private func reconcileCurrentEntry() {
        guard var session, let model, let id = model.currentQueueID, let index = model.currentIndex else { return }
        let track = model.queue[index].track
        if id == session.suggestionID { session.suggestionID = nil; session.suggestionTrack = nil }
        if !session.entryIDs.contains(id) || session.played.last?.id != track.id {
            if session.played.last?.id != track.id { session.played.append(track) }
            session.entryIDs.insert(id)
        }
        self.session = session
        if let suggestion = session.suggestionID {
            let follows = index + 1 < model.queue.count && model.queue[index + 1].id == suggestion
            if follows && model.settings.similarMixFollow == .seed { return }
            self.session?.suggestionID = nil; self.session?.suggestionTrack = nil
            removeQuietly(suggestion)
        }
        requestSuggestion()
    }

    private func requestSuggestion() {
        guard let session, let model else { return }
        searchTask?.cancel()
        isSearching = true; error = nil
        let seeds = Self.seeds(for: session, follow: model.settings.similarMixFollow)
        var excluded = session.skipped
        for track in session.played + model.queue.map(\.track) {
            excluded.insert(track.id); excluded.insert(SimilarityLibrary.editionKey(track))
        }
        let previous = model.currentTrack ?? session.played.last
        let reason = Self.reason(for: session, follow: model.settings.similarMixFollow)
        let sessionID = session.id
        let service = makeService()
        searchTask = Task { @MainActor [weak self] in
            do {
                guard let self else { return }
                let library = try await self.library(reusingSession: true)
                let candidates = try await service.candidates(for: seeds, in: library, excluding: excluded)
                guard !Task.isCancelled, self.session?.id == sessionID else { return }
                guard let next = self.chooseNext(candidates, previous) else { throw SimilarityError.noMatches }
                self.insertSuggestion(next, reason: reason)
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled, self.session?.id == sessionID else { return }
                self.isSearching = false
                self.error = error.localizedDescription
                if self.playsWhenReady {
                    self.playsWhenReady = false
                    self.model?.status = "Similar Mix: \(error.localizedDescription)"
                }
            }
        }
    }

    private func insertSuggestion(_ track: TrackRecord, reason: String) {
        guard var session, let model else { return }
        let item = QueueItem(track: track)
        editingQueue = true
        model.queue.insert(item, at: model.currentIndex.map { $0 + 1 } ?? model.queue.count)
        editingQueue = false
        model.saveQueue()
        session.suggestionID = item.id; session.suggestionTrack = track; session.suggestionReason = reason
        session.entryIDs.insert(item.id)
        self.session = session
        isSearching = false
        if playsWhenReady { playsWhenReady = false; model.playQueueItem(item.id, origin: .automatic) }
    }

    private func removeQuietly(_ id: UUID) {
        guard let model, let index = model.queue.firstIndex(where: { $0.id == id }) else { return }
        editingQueue = true
        model.queue.remove(at: index)
        editingQueue = false
        if model.selectedQueueID == id { model.selectedQueueID = nil }
        model.saveQueue()
    }

    // MARK: Fixed playlist

    /// Replaces the active playlist. A single seed track opens the playlist; other seeds are excluded.
    func generatePlaylist(_ seed: [TrackRecord], limit: Int?) {
        guard let model, !isGenerating else { return }
        let available = seed.filter(\.isAvailable)
        guard !available.isEmpty else { error = "These tracks are unavailable."; return }
        isGenerating = true; error = nil
        let seeds = Self.queryTracks(available).map { SimilaritySeed($0) }
        var excluded = Set<String>()
        for track in available { excluded.insert(track.id); excluded.insert(SimilarityLibrary.editionKey(track)) }
        let service = makeService()
        let opening = available.count == 1 ? available : []
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isGenerating = false }
            do {
                let library = try await self.library(reusingSession: false)
                let candidates = try await service.candidates(for: seeds, in: library, excluding: excluded)
                let ranked = SimilarityRanking.playlist(candidates, limit: limit.map { max(0, $0 - opening.count) })
                self.end()
                let (title, _) = Self.describe(available)
                if !model.replaceQueue(with: opening + ranked, name: "Similar Playlist", play: true).isEmpty {
                    model.status = "Created a similar playlist of \(opening.count + ranked.count) tracks from “\(title)”."
                    self.request = nil
                }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: Helpers

    private func makeService() -> SimilarityService {
        if let serviceOverride { return serviceOverride }
        let store = model?.store
        var providers: [any SimilarityProvider] = []
        if let client = model?.scrobbling?.similarityClient { providers.append(LastFMSimilarityProvider(client: client)) }
        providers.append(listenBrainz)
        return SimilarityService(providers: store.map { store in providers.map { CachedSimilarityProvider($0, store: store) } } ?? providers)
    }

    private func library(reusingSession: Bool) async throws -> SimilarityLibrary {
        if let libraryOverride { return libraryOverride }
        if reusingSession, let sessionLibrary { return sessionLibrary }
        guard let model, let store = model.store else { throw SimilarityError.noMatches }
        let eligible = Set(model.sources.filter { [.local, .openSubsonic].contains($0.kind) }.map(\.id))
        let library = try await Task.detached(priority: .utility) {
            SimilarityLibrary(tracks: try store.allTracks().filter { $0.isAvailable && eligible.contains($0.sourceID) })
        }.value
        if reusingSession { sessionLibrary = library }
        return library
    }

    static func startTrack(_ tracks: [TrackRecord]) -> TrackRecord? {
        guard tracks.count > 1 else { return tracks.first }
        return tracks.enumerated().max { $0.element.playCount != $1.element.playCount ? $0.element.playCount < $1.element.playCount : $0.offset > $1.offset }?.element
    }

    /// At most five representative tracks, most played first, to bound provider requests.
    static func queryTracks(_ tracks: [TrackRecord]) -> [TrackRecord] {
        Array(tracks.enumerated().sorted { $0.element.playCount != $1.element.playCount ? $0.element.playCount > $1.element.playCount : $0.offset < $1.offset }
            .map(\.element).prefix(5))
    }

    static func describe(_ tracks: [TrackRecord]) -> (title: String, subtitle: String) {
        guard let first = tracks.first else { return ("", "") }
        if tracks.count == 1 { return (first.title, first.artist) }
        if tracks.allSatisfy({ $0.albumID == first.albumID && $0.sourceID == first.sourceID }) { return (first.album, first.albumArtist) }
        if tracks.allSatisfy({ $0.albumArtist == first.albumArtist }) { return (first.albumArtist, "Artist") }
        return ("\(tracks.count) tracks", "")
    }

    static func seeds(for session: SimilarMixSession, follow: SimilarMixFollow) -> [SimilaritySeed] {
        let anchored = session.seed.map { SimilaritySeed($0) }
        let recent = session.played.filter { !session.skipped.contains($0.id) }
        switch follow {
        case .seed: return anchored
        case .lastPlayed: return recent.last.map { [SimilaritySeed($0)] } ?? anchored
        case .blend:
            let seedIDs = Set(session.seed.map(\.id))
            let latest = recent.filter { !seedIDs.contains($0.id) }.suffix(3).reversed()
            return anchored + zip(latest, [0.8, 0.6, 0.4]).map { SimilaritySeed($0.0, weight: $0.1) }
        }
    }

    static func reason(for session: SimilarMixSession, follow: SimilarMixFollow) -> String {
        let recent = session.played.filter { !session.skipped.contains($0.id) }
        switch follow {
        case .seed: return session.title
        case .lastPlayed: return recent.last?.title ?? session.title
        case .blend: return recent.last.map { $0.title == session.title ? session.title : "\(session.title) and \($0.title)" } ?? session.title
        }
    }
}
