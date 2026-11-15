import Foundation
import MacarokCore
import Observation
import SwiftUI

struct AlbumMetadataDraft: Equatable, Sendable {
    var album: String
    var albumArtist: String
    var artist: String
    var year: String
    var genre: String

    init(_ track: TrackRecord) {
        album = track.album; albumArtist = track.albumArtist; artist = track.artist
        year = track.year.map(String.init) ?? ""; genre = track.genre ?? ""
    }

    var isValid: Bool {
        !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (year.isEmpty || Int(year).map { (1...9999).contains($0) } == true)
    }

    func changes(from original: AlbumMetadataDraft) -> [MetadataFieldChange] {
        [("ALBUM", "Album", original.album, album), ("ALBUMARTIST", "Album artist", original.albumArtist, albumArtist),
         ("ARTIST", "Artist", original.artist, artist), ("DATE", "Year", original.year, year),
         ("GENRE", "Genre", original.genre, genre)].compactMap { key, label, before, after in
            before == after ? nil : MetadataFieldChange(key: key, label: label, before: before, after: after)
        }
    }

    static func applying(_ properties: [String: String], to latest: TrackRecord) -> TrackRecord {
        var edited = latest
        if let value = properties["ALBUM"] { edited.album = value }
        if let value = properties["ALBUMARTIST"] { edited.albumArtist = value }
        if let value = properties["ARTIST"] { edited.artist = value }
        if let value = properties["DATE"] { edited.year = Int(value) }
        if let value = properties["GENRE"] { edited.genre = value.isEmpty ? nil : value }
        return edited
    }
}

/// The original source and album identity stay fixed while playback or library navigation advances.
@MainActor @Observable
final class AlbumMetadataEditingSession: Identifiable {
    let id = UUID()
    let track: TrackRecord
    let originalDraft: AlbumMetadataDraft
    var draft: AlbumMetadataDraft
    var protectValues = true
    var isLoading = false
    var hasLoaded = false
    var isSaving = false
    var confirmSave = false
    var error: String?
    var tracks: [TrackRecord] = []

    init(track: TrackRecord) {
        self.track = track
        originalDraft = AlbumMetadataDraft(track)
        draft = originalDraft
    }

    var changes: [MetadataFieldChange] { draft.changes(from: originalDraft) }
    var properties: [String: String] { Dictionary(uniqueKeysWithValues: changes.map { ($0.key, $0.after) }) }
    var hasMixedArtists: Bool { Set(tracks.map(\.artist)).count > 1 }
}

struct AlbumMetadataEditor: View {
    @Bindable var model: AppModel
    @Bindable var session: AlbumMetadataEditingSession
    let onFinish: () -> Void

    private var isLocal: Bool { model.sources.first { $0.id == session.track.sourceID }?.kind == .local }
    private var saveLabel: String { isLocal ? "Save to Files" : "Save to Library" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text("Editing album: \(session.track.album)").lineLimit(1)
                Spacer(minLength: 0)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 18).frame(height: 34).background(.bar)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Edit Album Metadata").font(.title2.weight(.semibold))
                    HStack(alignment: .top, spacing: 15) {
                        ArtworkView(track: model.queueMetadataOverrides[session.track.id] ?? session.track, model: model).frame(width: 84, height: 84)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(session.track.album).font(.headline).lineLimit(2)
                            Text(session.isLoading ? "Loading album tracks…" : "\(session.tracks.count) tracks · \(model.sourceName(for: session.track.sourceID))")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Change Artwork…", systemImage: "photo") { model.artworkTrack = session.track }
                                .disabled(session.isSaving)
                            Text("Artwork is saved separately.").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    Form {
                        TextField("Album", text: $session.draft.album)
                        TextField("Album artist", text: $session.draft.albumArtist)
                        TextField("Artist (all tracks)", text: $session.draft.artist)
                        TextField("Year", text: $session.draft.year)
                        TextField("Genre", text: $session.draft.genre)
                    }.formStyle(.grouped).scrollDisabled(true).frame(minHeight: 255)
                    Text(session.hasMixedArtists
                         ? "This album contains different track artists. Only changed fields apply to every track; unchanged artist values are preserved."
                         : "Only changed fields apply to every track in this album. Track titles, disc and track numbers, and CUE boundaries are preserved.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !session.changes.isEmpty {
                        Text("Changes to Save").font(.headline)
                        ForEach(session.changes) { change in
                            HStack(alignment: .firstTextBaseline) {
                                Text(change.label).frame(width: 80, alignment: .leading).foregroundStyle(.secondary)
                                Text(change.after.isEmpty ? "Empty" : change.after).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.caption)
                        }
                    }
                    Toggle("Protect these corrections during library scans", isOn: $session.protectValues).toggleStyle(.checkbox)
                    Text(isLocal ? "Changes are written once to each original audio file and CUE sheet. Other metadata and audio are preserved."
                                 : "Corrections are stored in Macarok. The source's original audio files are not changed.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let error = session.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                }.padding(20)
            }.disabled(session.isSaving)
            Divider()
            HStack {
                if session.isSaving || session.isLoading { ProgressView().controlSize(.small) }
                if session.isSaving { Text("Saving album metadata…").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                Button("Cancel", action: onFinish).keyboardShortcut(.cancelAction).disabled(session.isSaving)
                Button(saveLabel) { session.confirmSave = true }.keyboardShortcut(.defaultAction)
                    .disabled(!session.draft.isValid || session.isSaving || session.isLoading || !session.hasLoaded || session.tracks.isEmpty ||
                              (session.changes.isEmpty && session.protectValues == session.track.metadataLocked))
            }.padding(16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .accessibilityIdentifier("albumMetadataEditor")
            .task(id: session.id) { await model.loadAlbumMetadata(session: session) }
            .confirmationDialog(saveLabel + "?", isPresented: $session.confirmSave, titleVisibility: .visible) {
                Button(saveLabel) { Task { await save() } }
            } message: {
                Text(isLocal ? "The changed shared fields will be written to every track in this album. Track-specific metadata is preserved."
                             : "These album corrections will be stored in Macarok. The source's audio files will not be changed.")
            }
    }

    private func save() async {
        guard !session.isSaving else { return }
        session.isSaving = true; session.error = nil
        defer { session.isSaving = false }
        do { try await model.applyAlbumMetadataEdits(session: session); onFinish() }
        catch is CancellationError { }
        catch { session.error = error.localizedDescription }
    }
}
