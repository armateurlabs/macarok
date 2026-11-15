import Foundation
import MacarokCore
import MacarokMetadata
import Observation
import SwiftUI

/// An editor owns its target and draft independently of the current playback entry or browsing scope.
@MainActor @Observable
final class MetadataEditingSession: Identifiable {
    let id = UUID()
    let track: TrackRecord
    var draft: MetadataDraft
    var protectValues = true
    var isBusy = false
    var isSaving = false
    var error: String?
    var releases: [MusicBrainzRelease] = []
    var proposal: MetadataProposal?
    var selectedFields: Set<String> = []
    var matchedReleaseID: String?
    var proposedReleaseName: String?
    var matchedReleaseName: String?
    var confirmSave = false
    var identifyRecording = false

    init(track: TrackRecord) { self.track = track; draft = MetadataDraft(track) }

    /// Keep newer artwork, playback statistics, and any tag the user did not change in this draft.
    func editedTrack(preserving latest: TrackRecord) -> TrackRecord {
        let original = MetadataDraft(track)
        var merged = MetadataDraft(latest)
        let fields: [WritableKeyPath<MetadataDraft, String>] = [
            \.title, \.artist, \.albumArtist, \.album, \.year, \.genre, \.trackNumber, \.discNumber
        ]
        for field in fields where draft[keyPath: field] != original[keyPath: field] {
            merged[keyPath: field] = draft[keyPath: field]
        }
        return merged.applying(to: latest)
    }
}

struct InlineMetadataEditor: View {
    @Bindable var model: AppModel
    let session: MetadataEditingSession
    let onFinish: () -> Void

    private var playbackMoved: Bool {
        guard let current = model.currentTrack else { return false }
        return current.id != session.track.id || current.sourceID != session.track.sourceID
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text("Editing \(session.track.title)").lineLimit(1)
                if playbackMoved, let current = model.currentTrack {
                    Text("· Now playing \(current.title)").lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 18).frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            MetadataEditor(model: model, session: session, onFinish: onFinish)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("inlineMetadataEditor")
    }
}
