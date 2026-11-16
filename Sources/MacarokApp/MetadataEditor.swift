import MacarokCore
import MacarokMetadata
import SwiftUI

struct MetadataEditor: View {
    @Bindable var model: AppModel
    let track: TrackRecord
    @Environment(\.dismiss) private var dismiss
    @State private var ownedSession: MetadataEditingSession
    @State private var isEditorVisible = false
    @State private var identificationPreparationTask: Task<Void, Never>?
    @State private var identificationRequestID: UUID?
    @State private var identificationAudioURL: URL?
    private let suppliedSession: MetadataEditingSession?
    private let onFinish: (() -> Void)?

    init(model: AppModel, track: TrackRecord) {
        self.model = model; self.track = track
        _ownedSession = State(initialValue: MetadataEditingSession(track: track))
        suppliedSession = nil; onFinish = nil
    }

    init(model: AppModel, session: MetadataEditingSession, onFinish: @escaping () -> Void) {
        self.model = model; track = session.track
        _ownedSession = State(initialValue: session)
        suppliedSession = session; self.onFinish = onFinish
    }

    private var session: MetadataEditingSession { suppliedSession ?? ownedSession }
    private var embedded: Bool { suppliedSession != nil }
    private var draft: MetadataDraft { get { session.draft } nonmutating set { session.draft = newValue } }
    private var protectValues: Bool { get { session.protectValues } nonmutating set { session.protectValues = newValue } }
    private var isBusy: Bool { get { session.isBusy } nonmutating set { session.isBusy = newValue } }
    private var isSaving: Bool { get { session.isSaving } nonmutating set { session.isSaving = newValue } }
    private var error: String? { get { session.error } nonmutating set { session.error = newValue } }
    private var releases: [MusicBrainzRelease] { get { session.releases } nonmutating set { session.releases = newValue } }
    private var proposal: MetadataProposal? { get { session.proposal } nonmutating set { session.proposal = newValue } }
    private var selectedFields: Set<String> { get { session.selectedFields } nonmutating set { session.selectedFields = newValue } }
    private var matchedReleaseID: String? { get { session.matchedReleaseID } nonmutating set { session.matchedReleaseID = newValue } }
    private var proposedReleaseName: String? { get { session.proposedReleaseName } nonmutating set { session.proposedReleaseName = newValue } }
    private var matchedReleaseName: String? { get { session.matchedReleaseName } nonmutating set { session.matchedReleaseName = newValue } }
    private var confirmSave: Bool { get { session.confirmSave } nonmutating set { session.confirmSave = newValue } }
    private var identifyRecording: Bool { get { session.identifyRecording } nonmutating set { session.identifyRecording = newValue } }

    private var isLocal: Bool { model.sources.first(where: { $0.id == track.sourceID })?.kind == .local }
    private var changes: [MetadataFieldChange] { draft.changes(from: track) }
    private var saveLabel: String { isLocal ? "Save to Files" : "Save to Library" }
    private var isPreparingIdentification: Bool { identificationPreparationTask != nil }

    var body: some View {
        @Bindable var session = self.session
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Edit Song Metadata").font(.title2.weight(.semibold))
                    Text(track.title).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if !embedded {
                    Button("Done", systemImage: "xmark", action: finish).labelStyle(.iconOnly).buttonStyle(.plain)
                        .disabled(isSaving).help("Close metadata editor")
                }
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if embedded { artworkSection }
                    Form {
                        TextField("Title", text: $session.draft.title)
                        TextField("Artist", text: $session.draft.artist)
                        TextField("Album artist", text: $session.draft.albumArtist)
                        TextField("Album", text: $session.draft.album)
                        HStack {
                            TextField("Year", text: $session.draft.year)
                            TextField("Track", text: $session.draft.trackNumber).disabled(track.isCUETrack)
                            TextField("Disc", text: $session.draft.discNumber).disabled(track.isCUETrack)
                        }
                        TextField("Genre", text: $session.draft.genre)
                    }.formStyle(.grouped).scrollDisabled(true).multilineTextAlignment(.leading)
                    .frame(minHeight: 300)

                    ViewThatFits(in: .horizontal) {
                        HStack {
                            lookupActions
                            Spacer(minLength: 0)
                            if isBusy || isPreparingIdentification { ProgressView().controlSize(.small) }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            lookupActions
                            if isBusy || isPreparingIdentification { ProgressView().controlSize(.small) }
                        }
                    }
                    if !releases.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Choose an edition").font(.headline)
                            ForEach(releases) { release in
                                Button { Task { await choose(release) } } label: {
                                    HStack(alignment: .top) {
                                        Image(systemName: "opticaldisc").font(.title2).foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(release.title).fontWeight(.medium)
                                            Text([release.artist, release.date, release.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                                .font(.caption).foregroundStyle(.secondary)
                                            if let detail = release.disambiguation, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer()
                                        Text("\(release.trackCount) tracks").font(.caption).foregroundStyle(.secondary)
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if let proposal {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Proposed Changes").font(.headline)
                            if proposal.changes.isEmpty { Text("These tags already match.").foregroundStyle(.secondary) }
                            ForEach(proposal.changes) { change in
                                Toggle(isOn: Binding(get: { selectedFields.contains(change.field) }, set: { enabled in
                                    if enabled { selectedFields.insert(change.field) } else { selectedFields.remove(change.field) }
                                })) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(fieldName(change.field)).fontWeight(.medium)
                                        HStack {
                                            Text(change.currentValue.isEmpty ? "Empty" : change.currentValue).foregroundStyle(.secondary)
                                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                            Text(change.proposedValue.isEmpty ? "Empty" : change.proposedValue)
                                        }.font(.caption)
                                    }
                                }.toggleStyle(.checkbox)
                            }
                            if !proposal.changes.isEmpty || proposal.releaseID != nil {
                                Button(proposal.changes.isEmpty ? "Use This Edition" : "Use Selected Changes") {
                                    draft = MetadataDraft(proposal.applying(to: draft.applying(to: track), fields: selectedFields))
                                    if let releaseID = proposal.releaseID { matchedReleaseID = releaseID; matchedReleaseName = proposedReleaseName }
                                    self.proposal = nil; releases = []
                                }.disabled(selectedFields.isEmpty && proposal.releaseID == nil)
                            }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if !changes.isEmpty || matchedReleaseID != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Changes to Save").font(.headline)
                            ForEach(changes) { change in
                                HStack(alignment: .top) {
                                    Text(change.label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                                    Text(change.before.isEmpty ? "Empty" : change.before).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                    Text(change.after.isEmpty ? "Empty" : change.after).frame(maxWidth: .infinity, alignment: .leading)
                                }.font(.caption)
                            }
                            if matchedReleaseID != nil {
                                HStack {
                                    Text("Album edition").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                                    Text(matchedReleaseName ?? draft.album).font(.caption)
                                    Spacer()
                                    Button("Clear Match") { matchedReleaseID = nil; matchedReleaseName = nil }.controlSize(.small)
                                }
                            }
                        }
                    }
                    Toggle("Protect these corrections during library scans", isOn: $session.protectValues).toggleStyle(.checkbox)
                    Text(destinationDescription).font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                }.padding(20)
            }.disabled(isSaving)
            Divider()
            HStack {
                if isSaving { ProgressView().controlSize(.small); Text("Saving metadata…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", action: finish).keyboardShortcut(.cancelAction).disabled(isSaving)
                Button(saveLabel) { confirmSave = true }.keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid || isSaving || isBusy || isPreparingIdentification || (changes.isEmpty && matchedReleaseID == nil && protectValues == track.metadataLocked))
            }.padding(16)
        }.frame(width: embedded ? nil : 680, height: embedded ? nil : 720)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil)
        .sheet(isPresented: $session.identifyRecording) {
            if let identificationAudioURL {
                IdentifyRecordingSheet(track: track, audioURL: identificationAudioURL) { match in
                    let value = match.proposal(for: draft.applying(to: track))
                    proposal = value; selectedFields = Set(value.changes.map(\.field)); releases = []
                    proposedReleaseName = nil
                }
            }
        }
        .onAppear { isEditorVisible = true }
        .onChange(of: session.id) { _, _ in cancelIdentificationPreparation() }
        .onDisappear { isEditorVisible = false; cancelIdentificationPreparation() }
        .confirmationDialog(saveLabel + "?", isPresented: $session.confirmSave, titleVisibility: .visible) {
            Button(saveLabel) { Task { await save() } }
        } message: {
            Text(isLocal ? "The changes shown above will be written to the original music metadata. Other tags are preserved." : "These corrections will be stored in Macarok. The server's audio files will not be changed.")
        }
    }

    private var artworkSection: some View {
        HStack(alignment: .top, spacing: 15) {
            ArtworkView(track: model.queueMetadataOverrides[track.id] ?? track, model: model)
                .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 6) {
                Text(track.album).font(.headline).lineLimit(2)
                Text(track.albumArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button("Change Artwork…", systemImage: "photo") { model.beginArtworkEditing(track) }
                    .disabled(isSaving)
                Text("Artwork is saved separately.").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var lookupActions: some View {
        Button("Find Metadata", systemImage: "magnifyingglass") { Task { await findMatches() } }
        Button("Identify Recording", systemImage: "waveform", action: prepareIdentification)
            .disabled(!isLocal || isBusy || isPreparingIdentification)
        Button("Clean Up Tags", systemImage: "wand.and.stars") { prepareCleanup() }
    }

    private func prepareIdentification() {
        cancelIdentificationPreparation()
        let requestID = UUID(), sessionID = session.id
        identificationRequestID = requestID
        error = nil
        identificationPreparationTask = Task { @MainActor in
            defer {
                if identificationRequestID == requestID {
                    identificationPreparationTask = nil
                    identificationRequestID = nil
                }
            }
            do {
                let url = try await model.prepareIdentificationFile(for: track)
                try Task.checkCancellation()
                guard identificationCanPresent(requestID: requestID, sessionID: sessionID) else { return }
                identificationAudioURL = url
                identifyRecording = true
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled,
                      identificationCanPresent(requestID: requestID, sessionID: sessionID) else { return }
                self.error = "Could not prepare audio identification: \(error.localizedDescription)"
            }
        }
    }

    private func identificationCanPresent(requestID: UUID, sessionID: UUID) -> Bool {
        isEditorVisible && identificationRequestID == requestID && session.id == sessionID &&
            (!embedded || model.metadataEditingSession?.id == sessionID)
    }

    private func cancelIdentificationPreparation() {
        identificationRequestID = nil
        identificationPreparationTask?.cancel()
        identificationPreparationTask = nil
        identificationAudioURL = nil
        identifyRecording = false
    }

    private func finish() {
        cancelIdentificationPreparation()
        if let onFinish { onFinish() } else { dismiss() }
    }

    private var destinationDescription: String {
        if !isLocal { return "This source provides no original file-write access. Changes are local library corrections." }
        if track.isCUETrack { return "CUE track titles and artists are stored separately from shared album tags. Audio boundaries and the original audio stream are preserved." }
        return "Changes are written to the audio file and indexed in your library. Unchanged and unknown tags are preserved."
    }

    private func fieldName(_ key: String) -> String {
        ["title": "Title", "artist": "Artist", "albumArtist": "Album artist", "album": "Album", "year": "Year", "genre": "Genre", "trackNumber": "Track", "discNumber": "Disc"][key] ?? key
    }

    private func findMatches() async {
        isBusy = true; error = nil; proposal = nil
        defer { isBusy = false }
        do {
            releases = try await MetadataServices.musicBrainz.searchReleases(artist: draft.albumArtist.isEmpty ? draft.artist : draft.albumArtist, album: draft.album)
            if releases.isEmpty { error = "No matching releases were found. Check the artist and album names." }
        } catch { self.error = error.localizedDescription }
    }

    private func choose(_ release: MusicBrainzRelease) async {
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            let detail = try await MetadataServices.musicBrainz.release(id: release.id)
            var value = MetadataServices.musicBrainz.proposal(for: draft.applying(to: track), release: detail)
            if track.isCUETrack { value.changes.removeAll { ["trackNumber", "discNumber"].contains($0.field) } }
            proposal = value; selectedFields = Set(value.changes.map(\.field))
            proposedReleaseName = [release.title, release.date, release.country].compactMap { $0 }.joined(separator: " · ")
        } catch { self.error = error.localizedDescription }
    }

    private func prepareCleanup() {
        let value = MetadataCleanup.proposal(for: draft.applying(to: track))
        proposal = value; selectedFields = Set(value.changes.map(\.field)); releases = []
    }

    private func save() async {
        isSaving = true; error = nil
        defer { isSaving = false }
        do {
            let target = track
            let latest = try await model.performLibraryWork { try $0.track(id: target.id) } ?? target
            guard latest.sourceID == target.sourceID else { throw AppFailure.missingSource }
            try await model.applyMetadataEdits(original: latest, edited: session.editedTrack(preserving: latest), releaseID: matchedReleaseID, lockMetadata: protectValues)
            finish()
        } catch { self.error = "Could not finish saving metadata: \(error.localizedDescription)" }
    }
}

private struct IdentifyRecordingSheet: View {
    let track: TrackRecord
    let audioURL: URL
    let onSelect: (AcoustIDRecordingMatch) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var clientKey = ""
    @State private var rememberKey = false
    @State private var hasStoredKey = false
    @State private var isBusy = false
    @State private var message: String?
    @State private var warning: String?
    @State private var error: String?
    @State private var matches: [AcoustIDRecordingMatch] = []
    @State private var lookupTask: Task<Void, Never>?

    private let chromaprint = ChromaprintClient()

    private var unavailableReason: String? {
        if track.isCUETrack { return AudioIdentificationError.cueSegmentUnsupported.localizedDescription }
        if !audioURL.isFileURL { return AudioIdentificationError.localFileRequired.localizedDescription }
        if !chromaprint.isAvailable { return AudioIdentificationError.helperUnavailable.localizedDescription }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Identify Recording").font(.title2.weight(.semibold))
            Text(track.title).foregroundStyle(.secondary).lineLimit(2)
            Text("Macarok creates a fingerprint locally, then sends the fingerprint and track duration to AcoustID. Your audio file and existing tags are not uploaded.")
                .font(.callout).foregroundStyle(.secondary)
            if let unavailableReason {
                Label(unavailableReason, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("AcoustID application client key", text: $clientKey)
                    HStack {
                        Toggle("Remember in Keychain", isOn: $rememberKey).toggleStyle(.checkbox)
                        Spacer()
                        Link("Get a Client Key", destination: URL(string: "https://acoustid.org/new-application")!)
                    }.font(.caption)
                    if hasStoredKey {
                        Button("Remove Stored Key") {
                            do { try AcoustIDClientKeyStore.delete(); hasStoredKey = false; rememberKey = false; clientKey = "" }
                            catch { self.error = error.localizedDescription }
                        }.controlSize(.small)
                    }
                }.disabled(isBusy)
            }
            if let warning { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).font(.callout) }
            if let message { Text(message).foregroundStyle(.secondary).font(.callout) }
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            if !matches.isEmpty {
                Text("Choose a recording to review its title and artist. Use Find Metadata afterward to select an album edition.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(matches) { match in
                            Button { onSelect(match); dismiss() } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: "waveform").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(match.title).fontWeight(.medium)
                                        Text(match.artist).font(.caption).foregroundStyle(.secondary)
                                        if !match.albums.isEmpty {
                                            Text(match.albums.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    Text("\(Int((match.score * 100).rounded()))% similarity").font(.caption).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 260)
            }
            HStack {
                if isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { lookupTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Identify") {
                    lookupTask = Task { await identify() }
                }.keyboardShortcut(.defaultAction)
                    .disabled(unavailableReason != nil || isBusy || clientKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 590)
            .task {
                guard unavailableReason == nil else { return }
                do {
                    if let key = try AcoustIDClientKeyStore.load() { clientKey = key; rememberKey = true; hasStoredKey = true }
                } catch { self.error = error.localizedDescription }
            }
            .onDisappear { lookupTask?.cancel() }
    }

    @MainActor
    private func identify() async {
        isBusy = true; error = nil; warning = nil; matches = []; message = "Creating audio fingerprint…"
        defer { isBusy = false }
        do {
            let fingerprint = try await chromaprint.fingerprint(url: audioURL, isCUETrack: track.isCUETrack)
            try Task.checkCancellation()
            warning = fingerprint.warning
            message = "Looking up the fingerprint…"
            let resolvedMatches = try await MetadataServices.acoustID.lookup(fingerprint, clientKey: clientKey)
            try Task.checkCancellation()
            matches = resolvedMatches
            if rememberKey { try AcoustIDClientKeyStore.save(clientKey); hasStoredKey = true }
            message = matches.isEmpty ? "Lookup completed. No recording metadata was found." : "Lookup completed. Choose a recording below."
        } catch is CancellationError { message = nil }
        catch { message = nil; if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
