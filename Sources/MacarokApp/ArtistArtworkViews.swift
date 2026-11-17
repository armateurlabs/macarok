import AppKit
import MacarokCore
import SwiftUI
import UniformTypeIdentifiers

/// The artist's picture, shared by all of the artist's albums. A music note stands in until one is found.
struct ArtistArtworkView: View {
    @Bindable var model: AppModel
    let name: String

    var body: some View {
        ArtworkImageView(path: model.artistArtworkPath(for: name), placeholder: "music.note", accessibilityLabel: "Picture of \(name)")
            .task(id: ArtistArtworkKey.make(name)) { await model.ensureArtistArtwork(name) }
            .contextMenu { ArtistArtworkMenu(model: model, name: name) }
    }
}

struct ArtistArtworkMenu: View {
    @Bindable var model: AppModel
    let name: String
    var body: some View {
        Button("Choose Artist Picture…") { model.beginArtistArtworkEditing(name) }
        Button("Search Web for Artist Picture…") { model.beginArtistArtworkEditing(name, search: true) }
        Divider()
        Button("Find Picture Automatically") { Task { await model.resetArtistArtwork(name) } }
    }
}

private struct ArtistPictureCandidate: Identifiable {
    var id = UUID()
    var name: String
    var detail: String
    var origin: String
    var preview: Data
    var original: Data?
    var remote: URL?
}

struct ArtistArtworkChooser: View {
    @Bindable var model: AppModel
    let target: ArtistArtworkTarget
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ArtistPictureCandidate] = []
    @State private var selection: UUID?
    @State private var isBusy = false
    @State private var isSaving = false
    @State private var searched = false
    @State private var error: String?
    @State private var imageTask: Task<Void, Never>?

    private var selected: ArtistPictureCandidate? { candidates.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose Artist Picture").font(.title2.weight(.semibold))
                    Text("\(target.name) · used for all of this artist's albums").foregroundStyle(.secondary).lineLimit(2)
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
                                Image(nsImage: image).resizable().scaledToFill().frame(width: 220, height: 220).clipped()
                            } else {
                                ContentUnavailableView("No Picture", systemImage: "music.note", description: Text("Choose an image from a file or search the web."))
                            }
                        }.frame(width: 220, height: 220)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 12) {
                            if let selected {
                                Text(selected.name).font(.headline)
                                Text(selected.detail).font(.caption).foregroundStyle(.secondary)
                                if let data = selected.original, let image = NSBitmapImageRep(data: data) {
                                    Text("\(image.pixelsWide) × \(image.pixelsHigh) pixels").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Button("Choose Image…", systemImage: "folder") { chooseFile() }
                            Button("Search Web", systemImage: "magnifyingglass") { Task { await searchWeb() } }.disabled(isBusy)
                            if isBusy { HStack { ProgressView().controlSize(.small); Text("Searching Last.fm and Wikipedia…").font(.caption).foregroundStyle(.secondary) } }
                        }.padding(.top, 8)
                    }
                    if !candidates.isEmpty {
                        Text("Available Pictures").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 125, maximum: 170), spacing: 12)], alignment: .leading, spacing: 14) {
                            ForEach(candidates) { candidate in
                                Button { select(candidate) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        if let image = NSImage(data: candidate.preview) {
                                            Image(nsImage: image).resizable().scaledToFill().frame(height: 118).frame(maxWidth: .infinity).clipped()
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
                    } else if searched && !isBusy && error == nil {
                        Text("No pictures were found for this artist.").foregroundStyle(.secondary)
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                }.padding(20)
            }.disabled(isSaving)
            Divider()
            HStack {
                if isSaving { ProgressView().controlSize(.small); Text("Saving picture…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button("Save to Library") { Task { await save() } }.keyboardShortcut(.defaultAction)
                    .disabled(selected?.original == nil || isBusy || isSaving)
            }.padding(16)
        }.frame(width: 660, height: 640)
        .task {
            if let path = model.artistArtworkPath(for: target.name), let data = FileManager.default.contents(atPath: path) {
                let current = ArtistPictureCandidate(name: "Current picture", detail: model.artistArtwork[target.id]?.origin ?? "Library",
                                                     origin: model.artistArtwork[target.id]?.origin ?? "Library", preview: data, original: data)
                candidates = [current]; selection = current.id
            }
            if target.searchesOnOpen { await searchWeb() }
        }
        .onDisappear { imageTask?.cancel() }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.prompt = "Choose Picture"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 32 * 1_024 * 1_024 else { throw AppFailure.invalidArtwork }
            let data = try ArtistArtworkServices.normalizedImage(Data(contentsOf: url))
            let candidate = ArtistPictureCandidate(name: "Selected file", detail: url.lastPathComponent, origin: "File", preview: data, original: data)
            candidates.insert(candidate, at: 0); selection = candidate.id; error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func searchWeb() async {
        error = nil; isBusy = true
        defer { isBusy = false; searched = true }
        do {
            let results = try await model.searchArtistImages(for: target.name)
            let known = Set(candidates.compactMap(\.remote))
            for result in results where !known.contains(result.imageURL) {
                guard !Task.isCancelled else { return }
                guard let preview = try? await ArtistArtworkServices.download(result.thumbnailURL) else { continue }
                candidates.append(ArtistPictureCandidate(name: result.title, detail: "\(result.origin) · \(result.detail)", origin: result.origin,
                                                         preview: preview, remote: result.imageURL))
            }
            if selection == nil, let first = candidates.first { select(first) }
        } catch { self.error = "Could not search for pictures: \(error.localizedDescription)" }
    }

    private func select(_ candidate: ArtistPictureCandidate) {
        selection = candidate.id; error = nil
        imageTask?.cancel()
        guard candidate.original == nil, let remote = candidate.remote else { return }
        imageTask = Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let data = try await ArtistArtworkServices.download(remote)
                guard !Task.isCancelled, let index = candidates.firstIndex(where: { $0.id == candidate.id }) else { return }
                candidates[index].original = data
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }

    private func save() async {
        guard let selected, let data = selected.original else { return }
        isSaving = true; error = nil
        defer { isSaving = false }
        do {
            try await model.saveArtistArtwork(data, name: target.name, origin: selected.origin)
            dismiss()
        } catch { self.error = "Could not save the picture: \(error.localizedDescription)" }
    }
}
