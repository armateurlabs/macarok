import Foundation
import MacarokCore

extension AppModel {
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

    var isEditingContext: Bool { metadataEditingSession != nil || editingTrack != nil || artworkTrack != nil }

    var playingContextTrack: TrackRecord? {
        if let track = metadataEditingSession?.track ?? editingTrack ?? artworkTrack { return track }
        if let currentTrack, selectedTrackID == nil || selectedTrackID == currentTrack.id { return currentTrack }
        return selectedTrack
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
    }

    func ensureMetadataEditingSession() {
        guard metadataEditingSession == nil, let track = playingContextTrack, !isRadioTrack(track) else { return }
        metadataEditingSession = MetadataEditingSession(track: track)
    }

    func beginMetadataEditing(_ track: TrackRecord? = nil) {
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
        if contextMode == .editMetadata { contextMode = .context }
        metadataEditingSession = nil
        followPlaybackContext()
    }
}
