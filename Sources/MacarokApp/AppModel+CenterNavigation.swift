import Foundation
import MacarokCore

extension AppModel {
    func recordUserCenterNavigation() { playingAutoSwitchPolicy.recordUserNavigation() }

    func selectCenterPage(_ page: CenterPage) {
        recordUserCenterNavigation()
        centerPage = page
    }

    func selectHomeFilter(_ filter: HomeFilter) {
        recordUserCenterNavigation()
        homeFilter = filter
    }

    func selectContextMode(_ mode: ContextMode) {
        recordUserCenterNavigation()
        contextMode = mode
    }

    func selectContextTab(_ tab: String) {
        recordUserCenterNavigation()
        contextTab = tab
    }

    func selectLibraryView(_ view: LibraryView) {
        if view == .home { recordUserCenterNavigation() }
        libraryView = view
    }

    func beginArtworkEditing(_ track: TrackRecord?) {
        guard let track else { return }
        recordUserCenterNavigation()
        artworkTrack = track
    }

    func showPlayingForPlaybackStart(origin: PlaybackStartOrigin) {
        if playingAutoSwitchPolicy.acceptStart(mode: settings.playingAutoSwitchMode,
                                               origin: origin, editing: isEditingContext) {
            centerPage = .playing
        }
    }

    var centerPage: CenterPage {
        get { contextPage == .home ? .home : .playing }
        set {
            if newValue == .home { contextPage = .home }
            else {
                if contextPage == .home { contextPage = .track }
                followPlaybackContext()
            }
        }
    }

    /// A retained draft is available when returning to its editor; only a visible editor or
    /// presented sheet pins the central target while playback advances.
    var isEditingContext: Bool {
        editingTrack != nil || artworkTrack != nil ||
            (contextMode == .editMetadata && metadataEditingSession != nil) ||
            (contextMode == .editAlbumMetadata && albumMetadataEditingSession != nil)
    }

    var playingContextTrack: TrackRecord? {
        if contextMode == .editAlbumMetadata, let session = albumMetadataEditingSession { return session.track }
        if contextMode == .editMetadata, let session = metadataEditingSession { return session.track }
        if let track = editingTrack ?? artworkTrack { return track }
        if let currentTrack, selectedTrackID == nil || selectedTrackID == currentTrack.id { return currentTrack }
        return selectedTrack
    }

    /// Lyrics normally follow the queue; a presented editor pins the same target as the rest of Playing.
    var lyricsContextTrack: TrackRecord? { isEditingContext ? playingContextTrack : currentTrack ?? selectedTrack }

    func contextModeDidChange(from previousMode: ContextMode) {
        let previousEditorTrack: TrackRecord?
        switch previousMode {
        case .editMetadata: previousEditorTrack = metadataEditingSession?.track
        case .editAlbumMetadata: previousEditorTrack = albumMetadataEditingSession?.track
        default: previousEditorTrack = nil
        }
        switch contextMode {
        case .editMetadata:
            if metadataEditingSession == nil, let track = previousEditorTrack, !isRadioTrack(track) {
                metadataEditingSession = MetadataEditingSession(track: track)
            } else { ensureMetadataEditingSession() }
        case .editAlbumMetadata:
            if albumMetadataEditingSession == nil, let track = previousEditorTrack, !isRadioTrack(track) {
                albumMetadataEditingSession = AlbumMetadataEditingSession(track: track)
            } else { ensureAlbumMetadataEditingSession() }
        default:
            // Ordinary view changes preserve manual inspection. Leaving a visible editor releases
            // its lock immediately, while its original draft remains available on return.
            guard previousMode != contextMode, let previousEditorTrack, centerPage == .playing else { return }
            if currentTrack == nil, !isEditingContext { inspect(previousEditorTrack, userInitiated: false) }
            else { followPlaybackContext() }
        }
    }

    /// A queue transition updates the inspected record without changing the user's selected view or library scope.
    func followPlaybackContext() {
        guard centerPage == .playing, !isEditingContext else { return }
        let track = currentTrack
        selectedTrackID = track?.id
        selectedAlbumID = track?.albumID
        selectedAlbumSourceID = track?.sourceID
        selectedArtist = track?.albumArtist
        selectedFolder = nil
        contextPage = .track
        if contextMode == .editMetadata { ensureMetadataEditingSession() }
        if contextMode == .editAlbumMetadata { ensureAlbumMetadataEditingSession() }
    }

    func ensureMetadataEditingSession() {
        guard metadataEditingSession == nil, let track = playingContextTrack, !isRadioTrack(track) else { return }
        metadataEditingSession = MetadataEditingSession(track: track)
    }

    func beginMetadataEditing(_ track: TrackRecord? = nil) {
        recordUserCenterNavigation()
        if metadataEditingSession == nil {
            guard let target = track ?? playingContextTrack, !isRadioTrack(target) else { return }
            metadataEditingSession = MetadataEditingSession(track: target)
        }
        contextPage = .track
        contextMode = .editMetadata
    }

    func finishMetadataEditing() {
        guard let session = metadataEditingSession else { return }
        finishMetadataEditing(sessionID: session.id)
    }

    func finishMetadataEditing(sessionID: UUID) {
        guard metadataEditingSession?.id == sessionID else { return }
        let wasEditing = contextMode == .editMetadata
        if wasEditing { contextMode = .context }
        metadataEditingSession = nil
        if wasEditing { followPlaybackContext() }
    }

    func ensureAlbumMetadataEditingSession() {
        guard albumMetadataEditingSession == nil, let track = playingContextTrack, !isRadioTrack(track) else { return }
        albumMetadataEditingSession = AlbumMetadataEditingSession(track: track)
    }

    func beginAlbumMetadataEditing(_ track: TrackRecord? = nil) {
        recordUserCenterNavigation()
        if albumMetadataEditingSession == nil {
            guard let target = track ?? playingContextTrack, !isRadioTrack(target) else { return }
            albumMetadataEditingSession = AlbumMetadataEditingSession(track: target)
        }
        contextPage = .track; contextMode = .editAlbumMetadata
    }

    func finishAlbumMetadataEditing(sessionID: UUID) {
        guard albumMetadataEditingSession?.id == sessionID else { return }
        let wasEditing = contextMode == .editAlbumMetadata
        if wasEditing { contextMode = .context }
        albumMetadataEditingSession = nil
        if wasEditing { followPlaybackContext() }
    }
}
