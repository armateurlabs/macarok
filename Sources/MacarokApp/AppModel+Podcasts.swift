import AppKit
import Foundation
import MacarokCore

extension AppModel {
    /// All Sources Home lists podcast episodes in their own sections, even without music.
    var showsPodcastHome: Bool { isAllSources && homeFilter == .all && !allPodcastEpisodes.isEmpty }

    /// Home counts; All Sources adds its shows, which are not part of the music totals.
    var homeLibrarySummary: String {
        let music = "\(albums.count) albums · \(tracks.count) tracks"
        let shows = podcastSourcesInScope.count
        guard isAllSources, shows > 0 else { return music }
        let podcasts = shows == 1 ? "1 show" : "\(shows) shows"
        return tracks.isEmpty ? "\(podcasts) · \(allPodcastEpisodes.count) episodes" : "\(music) · \(podcasts)"
    }

    func isPodcastTrack(_ track: TrackRecord?) -> Bool { track.map { sourcesByID[$0.sourceID]?.kind == .podcasts } == true }

    /// Episodes have no lyrics, Wikipedia article, or editable tags: Playing always shows their context,
    /// while the chosen view is kept for the next music track.
    var displayedContextMode: ContextMode { isPodcastTrack(playingContextTrack) ? .context : contextMode }

    var podcastSourcesInScope: [SourceRecord] { sources.filter { $0.kind == .podcasts && scopeIncludes(sourceID: $0.id) } }

    /// The Podcasts tab appears only when the scope contains a show, keeping music-only libraries at six tabs.
    var visibleLibraryViews: [LibraryView] {
        LibraryView.allCases.filter { $0 != .podcasts || !podcastSourcesInScope.isEmpty }
    }

    /// The show whose episodes and Home are presented: a selected podcast source, or a show opened in the Podcasts tab.
    var focusedPodcastShowID: String? {
        if let source = selectedSource, source.kind == .podcasts { return source.id }
        guard libraryView == .podcasts, let id = podcasts.openShowID, sourcesByID[id]?.kind == .podcasts else { return nil }
        return id
    }

    func openPodcastShow(_ sourceID: String) {
        guard sourcesByID[sourceID]?.kind == .podcasts else { return }
        recordUserCenterNavigation()
        podcasts.openShowID = sourceID
        libraryView = .podcasts
        contextPage = .home
    }

    func closePodcastShow() {
        recordUserCenterNavigation()
        podcasts.openShowID = nil
        contextPage = .home
    }

    func isDownloaded(_ track: TrackRecord) -> Bool {
        podcastDownloads?.downloads[PodcastDownloadsController.key(track)] != nil
    }

    /// Shows in scope; while searching, only shows with matching episodes.
    var podcastShowSummaries: [PodcastShowSummary] {
        let summaries = PodcastLibrary.shows(episodes: podcastEpisodes, sources: podcastSourcesInScope, state: podcasts.state,
                                             newestFirst: settings.librarySortOrder.isDescending(.podcasts))
        return search.isEmpty ? summaries : summaries.filter { $0.episodeCount > 0 }
    }

    func podcastEpisodes(showID: String?, filter: PodcastEpisodeFilter) -> [TrackRecord] {
        PodcastLibrary.episodes(podcastEpisodes, showID: showID, filter: filter, state: podcasts.state, isDownloaded: isDownloaded,
                                newestFirst: settings.librarySortOrder.isDescending(.podcasts))
    }

    func newPodcastEpisodes(now: Date = Date()) -> [TrackRecord] {
        PodcastLibrary.newEpisodes(podcastEpisodes, state: podcasts.state, now: now,
                                   newestFirst: settings.librarySortOrder.isDescending(.podcasts))
    }

    func inProgressPodcastEpisodes(showID: String? = nil, limit: Int = .max) -> [TrackRecord] {
        let episodes = showID.map { id in allPodcastEpisodes.filter { $0.sourceID == id } } ?? allPodcastEpisodes
        return PodcastLibrary.inProgress(episodes, state: podcasts.state, updatedAt: podcasts.updatedAt, limit: limit)
    }

    func showEpisodes(_ sourceID: String) -> [TrackRecord] { allPodcastEpisodes.filter { $0.sourceID == sourceID } }

    /// Unplayed episodes in listening order, oldest first.
    func unplayedEpisodes(showID: String) -> [TrackRecord] {
        PodcastLibrary.ordered(showEpisodes(showID).filter { podcasts.state($0).isUnplayed }, newestFirst: false)
    }

    func playFromBeginning(_ track: TrackRecord) {
        podcasts.setPlayed(false, tracks: [track])
        add([track], play: true)
    }

    var currentChapterIndex: Int? {
        PodcastController.chapterIndex(podcasts.currentChapters, at: displayedPlaybackPosition)
    }
    var canSeekChapters: Bool { podcasts.currentChapters.count > 1 && canSeekCurrent }

    func seekChapter(forward: Bool) {
        guard canSeekChapters else { return }
        let chapters = podcasts.currentChapters, position = displayedPlaybackPosition
        let target = forward ? PodcastController.nextChapterTarget(chapters, position: position)
                             : PodcastController.previousChapterTarget(chapters, position: position)
        if let target { seekPlayback(to: target) }
    }

    /// Seeks the playing episode, or starts the episode at that time.
    func playEpisode(_ track: TrackRecord, from seconds: Double) {
        if currentTrack?.id == track.id { seekPlayback(to: seconds); if [.paused, .stopped, .failed].contains(player.state) && playbackTask == nil { togglePlayback() } }
        else { playTracks([track], position: seconds) }
    }

    func copyFeedURL(_ sourceID: String) {
        guard let location = sourcesByID[sourceID]?.location else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(location, forType: .string)
        status = "Copied the feed URL."
    }
}
