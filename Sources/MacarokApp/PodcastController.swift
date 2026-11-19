import Foundation
import MacarokCore
import Observation

enum PodcastHubSegment: String, CaseIterable, Identifiable {
    case shows, new, inProgress, downloaded
    var id: String { rawValue }
    var title: String {
        switch self { case .shows: "Shows"; case .new: "New"; case .inProgress: "In Progress"; case .downloaded: "Downloaded" }
    }
}

/// Podcast state that the music catalog does not hold: show details, listening progress,
/// browsing position in the Podcasts tab, and quiet periodic feed refresh.
@MainActor @Observable
final class PodcastController {
    /// Shorter positions are previews; the last seconds usually hold only credits.
    nonisolated static let minimumProgress: Double = 30
    nonisolated static let finishedMargin: Double = 30
    static let refreshCheckInterval: Duration = .seconds(300)
    static let refreshConcurrency = 3

    private(set) var shows: [String: PodcastShowRecord] = [:]
    private(set) var progress: [String: PodcastProgressRecord] = [:]
    private(set) var isRefreshingInBackground = false
    /// Chapters of the playing episode; empty for music, radio, and episodes without chapters.
    private(set) var currentChapters: [PodcastChapter] = []
    @ObservationIgnored private var chapterMemo: [String: [PodcastChapter]] = [:]
    @ObservationIgnored private var chapterTask: Task<Void, Never>?
    var openShowID: String?
    var hubSegment: PodcastHubSegment = .shows
    var episodeFilter: PodcastEpisodeFilter = .all
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var lastRecorded: [String: Double] = [:]
    @ObservationIgnored private var attempts: [String: Date] = [:]
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?

    func start(model: AppModel) async {
        self.model = model
        await reload()
    }

    func reload() async {
        guard let model else { return }
        do {
            let loaded = try await model.performLibraryWork { store in (shows: try store.podcastShows(), progress: try store.podcastProgress()) }
            shows = loaded.shows; progress = loaded.progress
        } catch { model.fail("Could not read podcast state", error.localizedDescription) }
    }

    // MARK: Listening state

    nonisolated static func state(progress: PodcastProgressRecord?, track: TrackRecord) -> PodcastEpisodeState {
        guard let progress else { return track.lastPlayedAt == nil ? .unplayed : .played }
        if progress.isFinished { return .played }
        guard progress.position >= minimumProgress else { return .unplayed }
        let duration = progress.duration > 0 ? progress.duration : track.duration
        return .inProgress(position: progress.position, remaining: max(0, duration - progress.position))
    }

    func state(_ track: TrackRecord) -> PodcastEpisodeState { Self.state(progress: progress[track.id], track: track) }
    func updatedAt(_ track: TrackRecord) -> Date? { progress[track.id]?.updatedAt }

    /// Where an in-progress episode continues, a moment before the saved position.
    func resumePosition(for track: TrackRecord) -> Double? {
        guard isPodcast(track), case let .inProgress(position, _) = state(track) else { return nil }
        return max(0, position - 2)
    }

    /// Checkpoints the playing episode; called from the playback tick.
    func record(track: TrackRecord, position: Double, duration: Double) {
        guard isPodcast(track), position.isFinite else { return }
        if let last = lastRecorded[track.id], abs(last - position) < 4 { return }
        let existing = progress[track.id]
        if position < Self.minimumProgress && (existing == nil || existing?.isFinished == true) { return }
        lastRecorded[track.id] = position
        let total = duration > 0 ? duration : track.duration
        let finished = total > 0 && position >= total - Self.finishedMargin
        if finished && existing?.isFinished == true { return }
        save([PodcastProgressRecord(trackID: track.id, sourceID: track.sourceID, position: position, duration: total, isFinished: finished)])
    }

    func markCompleted(_ track: TrackRecord) {
        guard isPodcast(track), progress[track.id]?.isFinished != true else { return }
        setPlayed(true, tracks: [track])
    }

    /// Unplayed is stored explicitly so an earlier library play no longer counts as heard.
    func setPlayed(_ played: Bool, tracks: [TrackRecord]) {
        let records = tracks.filter(isPodcast).map { track in
            PodcastProgressRecord(trackID: track.id, sourceID: track.sourceID, position: played ? track.duration : 0,
                                  duration: progress[track.id]?.duration ?? track.duration, isFinished: played)
        }
        for track in tracks { lastRecorded[track.id] = nil }
        save(records)
    }

    private func save(_ records: [PodcastProgressRecord]) {
        guard !records.isEmpty else { return }
        for record in records { progress[record.trackID] = record }
        Task { [weak model] in try? await model?.performLibraryWork { try $0.savePodcastProgress(records) } }
    }

    private func isPodcast(_ track: TrackRecord) -> Bool { model?.sourcesByID[track.sourceID]?.kind.isPodcast == true }

    func notes(for track: TrackRecord) async -> String? {
        guard let model else { return nil }
        let id = track.id
        return try? await model.performLibraryWork { try $0.podcastNotes(trackID: id)?.notes }
    }

    // MARK: Chapters

    /// The publisher's JSON chapters, then chapters in the feed, then a chapter list in the notes.
    nonisolated static func resolveChapters(json: [PodcastChapter], feed: [PodcastChapter], notes: String, duration: Double) -> [PodcastChapter] {
        let limit = duration > 0 ? duration : nil
        for candidate in [json, feed] {
            let chapters = PodcastChapters.normalized(candidate, duration: limit)
            if !chapters.isEmpty { return chapters }
        }
        return PodcastChapters.fromNotes(notes, duration: duration)
    }

    nonisolated static func chapterIndex(_ chapters: [PodcastChapter], at position: Double) -> Int? {
        chapters.lastIndex { $0.start <= position + 0.25 }
    }

    /// Like Previous Track: past the first three seconds, return to the start of the current chapter.
    nonisolated static func previousChapterTarget(_ chapters: [PodcastChapter], position: Double) -> Double? {
        guard let index = chapterIndex(chapters, at: position) else { return nil }
        if position - chapters[index].start > 3 || index == 0 { return chapters[index].start }
        return chapters[index - 1].start
    }

    nonisolated static func nextChapterTarget(_ chapters: [PodcastChapter], position: Double) -> Double? {
        chapters.first { $0.start > position + 0.25 }?.start
    }

    /// JSON chapters are downloaded only when an episode is played or inspected, then cached.
    func chapters(for track: TrackRecord) async -> [PodcastChapter] {
        if let memo = chapterMemo[track.id] { return memo }
        guard let model, isPodcast(track), let source = model.sourcesByID[track.sourceID] else { return [] }
        let id = track.id
        guard let stored = try? await model.performLibraryWork({ store in
            (sources: try store.podcastChapterSources(trackID: id), cached: try store.cachedPodcastChapters(trackID: id))
        }) else { return [] }
        var payload = stored.cached
        if payload == nil, let url = stored.sources.url {
            payload = try? await model.transport(for: source).data(from: url)
            if let payload, (try? PodcastChapters.parseJSON(payload)) != nil {
                try? await model.performLibraryWork { try $0.savePodcastChapters(payload, trackID: id, sourceID: source.id) }
            }
        }
        let json = payload.flatMap { try? PodcastChapters.parseJSON($0) } ?? []
        let duration = model.currentTrack?.id == id && model.player.duration > 0 ? model.player.duration : track.duration
        let chapters = Self.resolveChapters(json: json, feed: stored.sources.chapters, notes: stored.sources.notes, duration: duration)
        // A failed download is retried on a later play rather than remembered as "no chapters".
        if payload != nil || stored.sources.url == nil { chapterMemo[id] = chapters }
        return chapters
    }

    func loadCurrentChapters() {
        chapterTask?.cancel()
        guard let track = model?.currentTrack, isPodcast(track) else { currentChapters = []; return }
        if let memo = chapterMemo[track.id] { currentChapters = memo; return }
        currentChapters = []
        chapterTask = Task { [weak self] in
            guard let chapters = await self?.chapters(for: track), !Task.isCancelled,
                  self?.model?.currentTrack?.id == track.id else { return }
            self?.currentChapters = chapters
        }
    }

    // MARK: Show details

    func saveFeed(sourceID: String, feed: PodcastFeed, validators: PodcastFeedValidators) async {
        guard let model else { return }
        let now = Date()
        do {
            try await model.performLibraryWork { try $0.savePodcastFeed(sourceID: sourceID, feed: feed, validators: validators, now: now) }
            shows[sourceID] = PodcastShowRecord(sourceID: sourceID, feed: feed, validators: validators, refreshedAt: now)
            chapterMemo.removeAll()
        } catch { attempts[sourceID] = now }
    }

    func recordRefresh(sourceID: String, error: String?) async {
        let now = Date()
        attempts[sourceID] = now
        try? await model?.performLibraryWork { try $0.markPodcastRefresh(sourceID: sourceID, error: error, now: now) }
        guard var show = shows[sourceID] else { return }
        if error == nil { show.refreshedAt = now; show.lastError = nil } else { show.lastError = error }
        shows[sourceID] = show
    }

    // MARK: Automatic refresh

    nonisolated static func due(sources: [SourceRecord], shows: [String: PodcastShowRecord], attempts: [String: Date],
                                interval: TimeInterval, now: Date) -> [String] {
        guard interval > 0 else { return [] }
        return sources.filter { source in
            guard source.kind == .podcasts else { return false }
            if let attempt = attempts[source.id], now.timeIntervalSince(attempt) < interval { return false }
            guard let refreshed = shows[source.id]?.refreshedAt else { return true }
            return now.timeIntervalSince(refreshed) >= interval
        }.map(\.id)
    }

    func startAutomaticRefresh() {
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDue()
                try? await Task.sleep(for: Self.refreshCheckInterval)
            }
        }
    }

    func stopAutomaticRefresh() { refreshLoop?.cancel(); refreshLoop = nil }

    func refreshDue(now: Date = Date()) async {
        guard let model else { return }
        let due = Self.due(sources: model.sources, shows: shows, attempts: attempts, interval: model.settings.podcastRefreshInterval, now: now)
        await refresh(sourceIDs: due)
    }

    /// Refreshes shows without the visible refresh progress, and never interrupts a manual refresh.
    func refresh(sourceIDs: [String]) async {
        guard let model, let store = model.store, !isRefreshingInBackground, !model.isRefreshing else { return }
        let sources = sourceIDs.compactMap { model.sourcesByID[$0] }.filter { $0.kind == .podcasts }
        guard !sources.isEmpty else { return }
        isRefreshingInBackground = true
        defer { isRefreshingInBackground = false }
        var changed: [String] = []
        for start in stride(from: 0, to: sources.count, by: Self.refreshConcurrency) {
            if Task.isCancelled { break }
            let batch = sources[start..<min(sources.count, start + Self.refreshConcurrency)]
            await withTaskGroup(of: String?.self) { group in
                for source in batch {
                    group.addTask { @MainActor in
                        ((try? await model.refreshPodcast(source, store: store)) ?? false) ? source.id : nil
                    }
                }
                for await id in group { if let id { changed.append(id) } }
            }
        }
        model.publishPodcastChanges(sourceIDs: changed)
    }
}
