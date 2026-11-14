import AppKit
import MacarokCore
import MacarokMetadata
import SwiftUI
import UniformTypeIdentifiers

private struct ArtworkCandidate: Identifiable {
    var id = UUID()
    var name: String
    var detail: String
    var preview: Data
    var original: Data?
    var remote: CoverArtwork?
}

struct ArtworkChooser: View {
    @Bindable var model: AppModel
    let track: TrackRecord
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ArtworkCandidate] = []
    @State private var selection: UUID?
    @State private var releases: [MusicBrainzRelease] = []
    @State private var isBusy = false
    @State private var isSaving = false
    @State private var error: String?
    @State private var embedInFiles = true
    @State private var saveSidecar = false
    @State private var confirmSave = false
    @State private var imageTask: Task<Void, Never>?

    private var selected: ArtworkCandidate? { candidates.first { $0.id == selection } }
    private var isLocal: Bool { model.sources.first(where: { $0.id == track.sourceID })?.kind == .local }
    private var saveLabel: String { isLocal && (embedInFiles || saveSidecar) ? "Save to Files" : "Save to Library" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose Artwork").font(.title2.weight(.semibold))
                    Text("\(track.albumArtist) · \(track.album)").foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).buttonStyle(.plain).disabled(isSaving)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 20) {
                        Group {
                            if let data = selected?.original ?? selected?.preview, let image = NSImage(data: data) {
                                Image(nsImage: image).resizable().scaledToFit()
                            } else {
                                ContentUnavailableView("No Artwork", systemImage: "photo", description: Text("Choose an image from a file or an online release."))
                            }
                        }.frame(width: 220, height: 220)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 12) {
                            if let selected {
                                Text(selected.name).font(.headline)
                                Text(selected.detail).font(.caption).foregroundStyle(.secondary)
                                if let data = selected.original, let image = NSBitmapImageRep(data: data) {
                                    Text("\(image.pixelsWide) × \(image.pixelsHigh) pixels").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Button("Choose Image…", systemImage: "folder") { chooseFile() }
                            Button("Search Web", systemImage: "magnifyingglass") { Task { await searchWeb() } }
                            if isBusy { HStack { ProgressView().controlSize(.small); Text("Retrieving artwork…").font(.caption).foregroundStyle(.secondary) } }
                        }.padding(.top, 8)
                    }
                    if !releases.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Choose an edition").font(.headline)
                            ForEach(releases) { release in
                                Button { Task { await loadWebArtwork(releaseID: release.id, name: release.title) } } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(release.title)
                                            Text([release.artist, release.date, release.country, release.disambiguation].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                    }.padding(8).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                    if !candidates.isEmpty {
                        Text("Available Artwork").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 125, maximum: 170), spacing: 12)], alignment: .leading, spacing: 14) {
                            ForEach(candidates) { candidate in
                                Button { select(candidate) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        if let image = NSImage(data: candidate.preview) {
                                            Image(nsImage: image).resizable().scaledToFit().frame(height: 118).frame(maxWidth: .infinity)
                                        }
                                        Text(candidate.name).font(.caption.weight(.medium)).lineLimit(1)
                                        Text(candidate.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(selection == candidate.id ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selection == candidate.id ? Color.accentColor : .clear, lineWidth: 2))
                                }.buttonStyle(.plain)
                                    .accessibilityLabel("\(candidate.name), \(candidate.detail)")
                                    .accessibilityAddTraits(selection == candidate.id ? .isSelected : [])
                            }
                        }
                    }
                    if isLocal {
                        VStack(alignment: .leading, spacing: 9) {
                            Toggle("Embed the front cover in this album's audio files", isOn: $embedInFiles)
                            Toggle("Also save as cover.jpg in the album folder", isOn: $saveSidecar)
                        }.toggleStyle(.checkbox)
                        Text("Existing front covers will be replaced. Other embedded images and audio data are preserved.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Artwork is saved in Macarok's library. This source does not provide original file-write access.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                }.padding(20)
            }.disabled(isSaving)
            Divider()
            HStack {
                if isSaving { ProgressView().controlSize(.small); Text("Saving artwork…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button(saveLabel) { confirmSave = true }.keyboardShortcut(.defaultAction)
                    .disabled(selected?.original == nil || isBusy || isSaving)
            }.padding(16)
        }.frame(width: 660, height: 700)
        .task {
            candidates = await model.localArtwork(for: track).map { ArtworkCandidate(name: $0.name, detail: $0.detail, preview: $0.data, original: $0.data) }
            selection = candidates.first?.id
        }
        .onDisappear { imageTask?.cancel() }
        .confirmationDialog("Use this artwork?", isPresented: $confirmSave, titleVisibility: .visible) {
            Button(saveLabel) { Task { await save() } }
        } message: {
            Text(isLocal && (embedInFiles || saveSidecar) ? "Apply the selected cover to this album. Existing front artwork and any selected cover.jpg files will be replaced." : "Use the selected cover in Macarok's library.")
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.prompt = "Choose Artwork"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 32 * 1_024 * 1_024 else { throw AppFailure.invalidArtwork }
            let data = try normalizedImage(Data(contentsOf: url))
            let candidate = ArtworkCandidate(name: "Selected file", detail: url.lastPathComponent, preview: data, original: data)
            candidates.insert(candidate, at: 0); selection = candidate.id; error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func searchWeb() async {
        error = nil; isBusy = true
        defer { isBusy = false }
        do {
            var releaseID = UserDefaults.standard.string(forKey: "Macarok.release.\(track.albumID)")
            if releaseID == nil, let url = track.url, url.isFileURL {
                releaseID = (try? await Task.detached { try TagLibMetadataService.properties(url: url)["MUSICBRAINZ_ALBUMID"]?.first }.value) ?? nil
            }
            if let releaseID { await loadWebArtwork(releaseID: releaseID, name: track.album) }
            else {
                releases = try await MetadataServices.musicBrainz.searchReleases(artist: track.albumArtist, album: track.album)
                if releases.isEmpty { error = "No matching releases were found." }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func loadWebArtwork(releaseID: String, name: String) async {
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            let covers = try await MetadataServices.musicBrainz.artwork(forReleaseID: releaseID)
            if covers.isEmpty { error = "Cover Art Archive has no artwork for this edition."; return }
            for cover in covers.prefix(8) {
                let data = try await MetadataServices.musicBrainz.imageData(for: cover, thumbnail: true)
                guard !Task.isCancelled, data.count <= 32 * 1_024 * 1_024, NSImage(data: data) != nil else { continue }
                candidates.append(ArtworkCandidate(name: cover.isFront ? "Front cover" : cover.types.joined(separator: ", "), detail: "Cover Art Archive · \(name)", preview: data, remote: cover))
            }
            UserDefaults.standard.set(releaseID, forKey: "Macarok.release.\(track.albumID)")
            releases = []
        } catch { self.error = error.localizedDescription }
    }

    private func select(_ candidate: ArtworkCandidate) {
        selection = candidate.id; error = nil
        imageTask?.cancel()
        guard candidate.original == nil, let remote = candidate.remote else { return }
        imageTask = Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let original = try await MetadataServices.musicBrainz.imageData(for: remote)
                let data = try normalizedImage(original)
                guard !Task.isCancelled, let index = candidates.firstIndex(where: { $0.id == candidate.id }) else { return }
                candidates[index].original = data
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }

    private func normalizedImage(_ data: Data) throws -> Data {
        guard data.count <= 32 * 1_024 * 1_024, let image = NSImage(data: data) else { throw AppFailure.invalidArtwork }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: [0xFF, 0xD8]) { return data }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw AppFailure.invalidArtwork }
        return png
    }

    private func save() async {
        guard let data = selected?.original else { return }
        isSaving = true; error = nil
        defer { isSaving = false }
        do {
            try await model.saveAlbumArtwork(data: data, for: track, embedInFiles: isLocal && embedInFiles, saveSidecar: isLocal && saveSidecar)
            dismiss()
        } catch { self.error = "Could not finish saving artwork: \(error.localizedDescription)" }
    }
}
