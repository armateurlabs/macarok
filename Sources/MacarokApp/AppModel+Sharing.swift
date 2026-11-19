import AppKit
import MacarokCore

extension AppModel {
    /// What the macOS share menu sends: the song and its links, a station and what it plays, or an episode and its page.
    func shareText(for track: TrackRecord) async -> String {
        let kind = sourcesByID[track.sourceID]?.kind
        if kind == .radio {
            let station = radio?.stations.first { $0.id == track.id && $0.sourceID == track.sourceID }
            let isCurrent = currentTrack?.id == track.id && currentTrack?.sourceID == track.sourceID
            let website = station?.homepage.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil }
                ?? (isCurrent ? radioStreamInfo?.homepage : nil)
            return ShareText.radio(station: track.title, nowPlaying: isCurrent ? radioBroadcastTitle : nil, website: website)
        }
        if kind?.isPodcast == true {
            let episodeLink = try? await performLibraryWork { store in try store.podcastNotes(trackID: track.id)?.link }
            let link = (episodeLink ?? nil).flatMap(URL.init(string:))
                ?? podcasts.shows[track.sourceID]?.link.flatMap(URL.init(string:))
                ?? track.url.flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil }
            return ShareText.podcast(show: track.album, episode: track.title, link: link)
        }
        guard let key = SongKey(track: track), let songLinks else { return ShareText.song(title: track.title, artist: track.artist, links: []) }
        return ShareText.song(title: track.title, artist: key.artist, links: await songLinks.shareLinks(for: key))
    }

    func share(_ track: TrackRecord?, from view: NSView? = nil) {
        guard let track else { return }
        Task { [weak view] in
            let text = await shareText(for: track)
            SharePresenter.show(text, from: view)
        }
    }
}
