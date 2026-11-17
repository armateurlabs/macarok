import AppKit
import MacarokCore
import SwiftUI

/// Library pane for Internet Archive sources: collections load page by page as they are browsed.
struct ArchiveLibraryView: View {
    @Bindable var model: AppModel
    @Bindable var controller: InternetArchiveController
    let source: SourceRecord

    private var collection: ArchiveCollection { source.archiveCollection ?? .liveMusic }
    private var path: [ArchiveRoute] { controller.path(for: source) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: Binding(get: { controller.tab(for: source) }, set: { controller.tabs[source.id] = $0 })) {
                ForEach(ArchiveTab.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            if let route = path.last {
                HStack(spacing: 6) {
                    Button { controller.popToRoot(source: source) } label: { Image(systemName: "house").frame(width: 20, height: 18).contentShape(Rectangle()) }
                        .buttonStyle(.borderless).help("Back to \(controller.tab(for: source).title)")
                        .accessibilityLabel("Back to \(controller.tab(for: source).title)")
                    Button { controller.pop(source: source) } label: { Image(systemName: "chevron.left").frame(width: 20, height: 18).contentShape(Rectangle()) }
                        .buttonStyle(.borderless).help("Back").accessibilityLabel("Back")
                    Text(route.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 12).padding(.bottom, 6)
            }
            Group {
                if let route = path.last { routeView(route).id(route) }
                else { rootView }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = controller.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).padding(.horizontal, 13).padding(.vertical, 6)
            }
            LibraryPanelFooter(model: model, summary: .archive(saved: controller.savedItems(source).count))
        }
        .task(id: source.id) { await controller.reload(sourceID: source.id) }
    }

    @ViewBuilder private var rootView: some View {
        switch controller.tab(for: source) {
        case .browse:
            if collection == .liveMusic { ArchiveArtistsView(controller: controller, source: source) }
            else { ArchiveBooksView(controller: controller, source: source) }
        case .saved:
            ArchiveRecordList(controller: controller, source: source, records: controller.savedItems(source),
                              emptyTitle: collection == .liveMusic ? "No Saved Shows" : "No Saved Books",
                              emptyDetail: "Save an item to keep it in your library.")
        case .recent:
            ArchiveRecordList(controller: controller, source: source, records: controller.recentItems(source),
                              emptyTitle: "Nothing Played Yet", emptyDetail: "Items you open for playback appear here.")
        }
    }

    @ViewBuilder private func routeView(_ route: ArchiveRoute) -> some View {
        switch route {
        case let .artist(id, name): ArchiveYearsView(controller: controller, source: source, artistID: id, artistName: name)
        case let .shows(id, name, year):
            ArchiveResultsList(controller: controller, source: source, request: .shows(artist: id, year: year), style: .show) { result in
                controller.push(.item(id: result.id, title: result.date.map { "\($0) \(result.venue ?? name)" } ?? result.title), source: source)
            }
        case let .item(id, _): ArchiveItemView(model: model, controller: controller, source: source, identifier: id)
        }
    }
}

// MARK: Browse roots

private struct ArchiveArtistsView: View {
    @Bindable var controller: InternetArchiveController
    let source: SourceRecord
    @State private var draft = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                SearchField(prompt: "Search artists", text: $draft, focus: $searchFocused, onSubmit: { controller.artistSearch = draft })
                Picker("Sort", selection: $controller.artistSort) {
                    ForEach([ArchiveSort.popular, .alphabetical]) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize()
            }.padding(.horizontal, 12)
            ArchiveResultsList(controller: controller, source: source,
                               request: .artists(search: controller.artistSearch, sort: controller.artistSort), style: .artist) { result in
                controller.push(.artist(id: result.id, name: result.title), source: source)
            }
        }
        .onAppear { draft = controller.artistSearch }
        .onChange(of: draft) { _, value in if value.isEmpty, !controller.artistSearch.isEmpty { controller.artistSearch = "" } }
    }
}

private struct ArchiveBooksView: View {
    @Bindable var controller: InternetArchiveController
    let source: SourceRecord
    @State private var draft = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            SearchField(prompt: "Search titles or authors", text: $draft, focus: $searchFocused, onSubmit: { controller.bookSearch = draft })
                .padding(.horizontal, 12)
            HStack(spacing: 6) {
                Picker("Language", selection: $controller.bookLanguage) {
                    Text("All Languages").tag("")
                    Divider()
                    ForEach(InternetArchiveClient.languages, id: \.code) { Text($0.name).tag($0.code) }
                }.labelsHidden()
                Picker("Sort", selection: $controller.bookSort) {
                    ForEach(ArchiveSort.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize()
            }.padding(.horizontal, 12)
            ArchiveResultsList(controller: controller, source: source,
                               request: .books(search: controller.bookSearch, language: controller.bookLanguage.isEmpty ? nil : controller.bookLanguage,
                                               sort: controller.bookSort), style: .book) { result in
                controller.push(.item(id: result.id, title: result.title), source: source)
            }
        }
        .onAppear { draft = controller.bookSearch }
        .onChange(of: draft) { _, value in if value.isEmpty, !controller.bookSearch.isEmpty { controller.bookSearch = "" } }
    }
}

// MARK: Paged results

@MainActor @Observable
private final class ArchivePagedResults {
    var results: [ArchiveSearchResult] = []
    var total = 0
    var page = 0
    var isLoading = false
    var isStale = false
    var error: String?
    var hasMore: Bool { page == 0 || results.count < total }
    @ObservationIgnored private var generation = 0

    func load(_ request: ArchiveBrowseRequest, controller: InternetArchiveController, source: SourceRecord, reset: Bool) async {
        if reset { generation &+= 1; results = []; total = 0; page = 0; isStale = false; error = nil; isLoading = false }
        guard !isLoading, hasMore else { return }
        // A newer request supersedes this one; its late response is discarded.
        let current = generation
        isLoading = true; defer { if generation == current { isLoading = false } }
        do {
            let response = try await controller.search(request, source: source, page: page + 1)
            guard generation == current, !Task.isCancelled else { return }
            let known = Set(results.map(\.id))
            results += response.value.results.filter { !known.contains($0.id) }
            total = response.value.results.isEmpty ? results.count : response.value.total
            page = response.value.page
            isStale = isStale || response.isStale
            error = nil
        } catch is CancellationError {
        } catch { if generation == current, !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

private enum ArchiveRowStyle { case artist, show, book }

private struct ArchiveResultsList: View {
    @Bindable var controller: InternetArchiveController
    let source: SourceRecord
    let request: ArchiveBrowseRequest
    let style: ArchiveRowStyle
    let select: (ArchiveSearchResult) -> Void
    @State private var loader = ArchivePagedResults()

    var body: some View {
        Group {
            if loader.results.isEmpty && loader.isLoading {
                ProgressView("Loading from the Internet Archive…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loader.results.isEmpty, let error = loader.error {
                ArchiveErrorView(message: error) { Task { await loader.load(request, controller: controller, source: source, reset: true) } }
            } else if loader.results.isEmpty && !loader.isLoading && loader.page > 0 {
                ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text("Try other words or another filter."))
            } else {
                List {
                    if loader.isStale { ArchiveStaleNotice() }
                    ForEach(loader.results) { result in
                        Button { select(result) } label: { row(result) }.buttonStyle(.plain)
                            .contextMenu {
                                Link("Open on archive.org", destination: URL(string: "https://archive.org/details/")!.appendingPathComponent(result.id))
                            }
                    }
                    if loader.hasMore && loader.page > 0 {
                        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                            .onAppear { Task { await loader.load(request, controller: controller, source: source, reset: false) } }
                    }
                    if let error = loader.error, !loader.results.isEmpty {
                        Button("Retry") { Task { await loader.load(request, controller: controller, source: source, reset: false) } }
                            .help(error)
                    }
                }.listStyle(.inset(alternatesRowBackgrounds: true))
                    .background(NativeListBackground(revision: loader.results.count))
            }
        }
        .task(id: request) { await loader.load(request, controller: controller, source: source, reset: true) }
    }

    @ViewBuilder private func row(_ result: ArchiveSearchResult) -> some View {
        switch style {
        case .artist:
            HStack {
                Text(result.title).lineLimit(1)
                Spacer()
                if let count = result.itemCount { Text("\(count)").font(.system(size: 10)).foregroundStyle(.tertiary) }
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
            }.font(.system(size: 12)).padding(.vertical, 2).contentShape(Rectangle())
        case .show:
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text([result.date, result.venue].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? result.title).lineLimit(1)
                    Text([result.coverage, result.recordingSource].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? result.id)
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let rating = result.rating { ArchiveRating(value: rating) }
            }.font(.system(size: 12)).padding(.vertical, 2).contentShape(Rectangle())
        case .book:
            HStack(spacing: 9) {
                ArchiveArtwork(controller: controller, source: source, identifier: result.id, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title).lineLimit(1)
                    Text(result.creator.nonEmpty ?? "Unknown author").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }.font(.system(size: 12)).padding(.vertical, 2).contentShape(Rectangle())
        }
    }
}

private struct ArchiveYearsView: View {
    @Bindable var controller: InternetArchiveController
    let source: SourceRecord
    let artistID: String
    let artistName: String
    @State private var years: [ArchiveYearCount] = []
    @State private var isStale = false
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading && years.isEmpty {
                ProgressView("Loading years…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error, years.isEmpty {
                ArchiveErrorView(message: error) { Task { await load() } }
            } else if years.isEmpty {
                ContentUnavailableView("No Recordings", systemImage: "music.mic", description: Text("This collection has no audio recordings."))
            } else {
                List {
                    if isStale { ArchiveStaleNotice() }
                    ForEach(years) { year in
                        Button { controller.push(.shows(artistID: artistID, artistName: artistName, year: year.year), source: source) } label: {
                            HStack {
                                Text(String(year.year))
                                Spacer()
                                Text("\(year.count) recordings").font(.system(size: 10)).foregroundStyle(.tertiary)
                                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }.font(.system(size: 12)).padding(.vertical, 2).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.listStyle(.inset(alternatesRowBackgrounds: true))
                    .background(NativeListBackground(revision: years.count))
            }
        }.task(id: artistID) { await load() }
    }

    private func load() async {
        isLoading = true; error = nil; defer { isLoading = false }
        do {
            let response = try await controller.years(artist: artistID, source: source)
            years = response.value; isStale = response.isStale
        } catch is CancellationError {
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

// MARK: Saved and recent items

private struct ArchiveRecordList: View {
    @Bindable var controller: InternetArchiveController
    let source: SourceRecord
    let records: [ArchiveItemRecord]
    let emptyTitle: String
    let emptyDetail: String

    var body: some View {
        if records.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: source.archiveCollection == .librivox ? "book" : "music.mic", description: Text(emptyDetail))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(records) { record in
                Button { controller.push(.item(id: record.identifier, title: record.title), source: source) } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.title).lineLimit(1)
                            Text(record.subtitle.nonEmpty ?? record.creator).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if record.resumeTrackID != nil, source.archiveCollection == .librivox {
                            Image(systemName: "bookmark.fill").font(.system(size: 9)).foregroundStyle(.secondary).help("In progress")
                        }
                        if record.isSaved { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow).help("Saved") }
                    }.font(.system(size: 12)).padding(.vertical, 2).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .contextMenu {
                        Button(record.isSaved ? "Remove from Saved" : "Save to Library") {
                            Task { await controller.setSaved(!record.isSaved, identifier: record.identifier, source: source) }
                        }
                        Link("Open on archive.org", destination: URL(string: "https://archive.org/details/")!.appendingPathComponent(record.identifier))
                    }
            }.listStyle(.inset(alternatesRowBackgrounds: true))
                .background(NativeListBackground(revision: records.hashValue))
        }
    }
}

// MARK: Item

private struct ArchiveItemView: View {
    @Bindable var model: AppModel
    @Bindable var controller: InternetArchiveController
    let source: SourceRecord
    let identifier: String
    @State private var item: ArchiveItem?
    @State private var isStale = false
    @State private var error: String?
    @State private var expandsDescription = false

    private var record: ArchiveItemRecord? { controller.record(source, identifier: identifier) }
    private var isBook: Bool { source.archiveCollection == .librivox }

    var body: some View {
        Group {
            if let item { content(item) }
            else if let error { ArchiveErrorView(message: error) { Task { await load() } } }
            else { ProgressView("Loading item…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task(id: identifier) { await load() }
    }

    private func load() async {
        error = nil
        do {
            let response = try await controller.item(identifier, source: source)
            item = response.value; isStale = response.isStale
        } catch is CancellationError {
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func content(_ item: ArchiveItem) -> some View {
        let tracks = controller.previewTracks(item, source: source)
        let busy = controller.isBusy(item.identifier)
        return List {
            if isStale { ArchiveStaleNotice() }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 10) {
                        ArchiveArtwork(controller: controller, source: source, identifier: item.identifier, size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(3)
                            if !item.creator.isEmpty { Text(item.creator).font(.system(size: 11)).foregroundStyle(.secondary) }
                            Text(details(item)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    HStack(spacing: 8) {
                        if isBook, let point = controller.resumePoint(record), let chapter = tracks.first(where: { $0.id == point.trackID }) {
                            Button { Task { await controller.resume(item, source: source) } } label: { Label("Resume", systemImage: "play.fill") }
                                .help("Continue “\(chapter.title)” at \(point.position.playbackTime)")
                        }
                        Button { Task { await controller.play(item, source: source) } } label: {
                            Label(isBook && controller.resumePoint(record) != nil ? "Start Over" : "Play", systemImage: "play")
                        }
                        Button { Task { await controller.add(item, source: source) } } label: { Label("Add", systemImage: "text.badge.plus") }
                            .help("Add to the active playlist")
                        Button { Task { await controller.setSaved(!(record?.isSaved ?? false), item: item, source: source) } } label: {
                            Label(record?.isSaved == true ? "Saved" : "Save", systemImage: record?.isSaved == true ? "star.fill" : "star")
                        }.help(record?.isSaved == true ? "Remove from your library" : "Keep in your library")
                        if busy { ProgressView().controlSize(.mini) }
                    }.buttonStyle(.borderless).font(.system(size: 11)).disabled(busy || tracks.isEmpty)
                    HStack(spacing: 10) {
                        if isBook, model.podcastDownloads != nil {
                            Button("Download Book", systemImage: "arrow.down.circle") { Task { await controller.download(item, source: source) } }
                                .disabled(busy || tracks.isEmpty)
                        }
                        Link("Open on archive.org", destination: item.pageURL)
                    }.buttonStyle(.borderless).font(.system(size: 11))
                    if !item.description.isEmpty {
                        Text(item.description).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(expandsDescription ? nil : 4).textSelection(.enabled)
                        Button(expandsDescription ? "Less" : "More") { expandsDescription.toggle() }
                            .buttonStyle(.borderless).font(.system(size: 10))
                    }
                }.padding(.vertical, 4)
            }
            Section(isBook ? "Chapters" : "Tracks") {
                if tracks.isEmpty {
                    Text("No streamable audio in this item.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(tracks) { track in
                    ArchiveTrackRow(model: model, track: track, isResumePoint: isBook && controller.resumePoint(record)?.trackID == track.id)
                        .onTapGesture(count: 2) { Task { await controller.play(item, source: source, from: track.id) } }
                        .contextMenu {
                            Button("Play from Here") { Task { await controller.play(item, source: source, from: track.id) } }
                            Button("Add to Playlist") { Task { await controller.add(item, source: source, trackID: track.id) } }
                            Button("Add After Current Track") { Task { await controller.add(item, source: source, afterCurrent: true, trackID: track.id) } }
                            if isBook, let downloads = model.podcastDownloads, model.sourcesByID[track.sourceID] != nil {
                                let key = PodcastDownloadsController.key(track)
                                Divider()
                                if let download = downloads.downloads[key] {
                                    Button("Reveal in Finder") { downloads.reveal(download) }
                                    Button("Remove Download") { downloads.remove(download) }.disabled(!downloads.canRemove(download))
                                } else if downloads.isDownloading(track) {
                                    Button("Cancel Download") { downloads.cancel(track) }
                                } else {
                                    Button("Download Chapter") {
                                        Task { await controller.download(item, source: source, trackID: track.id) }
                                    }
                                }
                            }
                        }
                }
            }
        }.listStyle(.inset(alternatesRowBackgrounds: true))
            .background(NativeListBackground(revision: tracks.count))
    }

    private func details(_ item: ArchiveItem) -> String {
        if isBook {
            let language = item.language.flatMap { code in InternetArchiveClient.languages.first { $0.code == code }?.name ?? code }
            return [language, "LibriVox"].compactMap { $0 }.joined(separator: " · ")
        }
        return [[item.date, item.venue, item.coverage].compactMap { $0 }.joined(separator: " · "),
                item.recordingSource.map { "Source: \($0)" }, item.lineage.map { "Lineage: \($0)" }]
            .compactMap { $0?.nonEmpty }.joined(separator: "\n")
    }
}

private struct ArchiveTrackRow: View {
    @Bindable var model: AppModel
    let track: TrackRecord
    let isResumePoint: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(track.trackNumber.map(String.init) ?? "").font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
            Text(track.title).lineLimit(1)
            if isResumePoint { Image(systemName: "bookmark.fill").font(.system(size: 9)).foregroundStyle(.secondary).help("Where you stopped") }
            Spacer()
            if let downloads = model.podcastDownloads {
                let key = PodcastDownloadsController.key(track)
                if downloads.downloads[key] != nil { Image(systemName: "arrow.down.circle.fill").font(.system(size: 9)).foregroundStyle(.secondary).help("Downloaded") }
                else if let progress = downloads.progress[key] {
                    if let fraction = progress.fraction { ProgressView(value: fraction).frame(width: 40) } else { ProgressView().controlSize(.mini) }
                }
            }
            Text(track.format).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(track.duration > 0 ? track.formattedDuration : "").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
        }.font(.system(size: 12)).padding(.vertical, 1).contentShape(Rectangle())
    }
}

// MARK: Shared

/// Saved items use their cached cover; others load the archive.org thumbnail on demand.
private struct ArchiveArtwork: View {
    let controller: InternetArchiveController
    let source: SourceRecord
    let identifier: String
    let size: CGFloat

    var body: some View {
        Group {
            if let path = controller.artworkPath(source, identifier: identifier), let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().scaledToFill()
            } else if controller.loadsRemoteArtwork {
                AsyncImage(url: InternetArchiveClient.artworkURL(identifier: identifier)) { image in image.resizable().scaledToFill() }
                    placeholder: { placeholder }
            } else { placeholder }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size > 40 ? 5 : 4))
    }

    private var placeholder: some View {
        Color.secondary.opacity(0.12).overlay {
            Image(systemName: source.archiveCollection == .librivox ? "book" : "music.mic").foregroundStyle(.tertiary)
        }
    }
}

private struct ArchiveRating: View {
    let value: Double
    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: "star.fill").font(.system(size: 8))
            Text(value, format: .number.precision(.fractionLength(1))).font(.system(size: 10)).monospacedDigit()
        }.foregroundStyle(.secondary).help("Average listener rating")
    }
}

private struct ArchiveStaleNotice: View {
    var body: some View {
        Label("The Internet Archive could not be reached. Showing earlier results.", systemImage: "wifi.exclamationmark")
            .font(.system(size: 10)).foregroundStyle(.secondary)
    }
}

private struct ArchiveErrorView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Could Not Load", systemImage: "exclamationmark.triangle")
        } description: { Text(message) } actions: { Button("Try Again", action: retry) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
