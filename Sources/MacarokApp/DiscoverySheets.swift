import MacarokCore
import SwiftUI

struct PodcastDiscoverySheet: View {
    @Environment(\.dismiss) private var dismiss
    let choose: (PodcastDirectoryResult) -> Void
    @State private var client = PodcastDirectoryClient()
    @State private var provider: PodcastDirectoryProvider = .podcastIndex
    @State private var query = ""
    @State private var results: [PodcastDirectoryResult] = []
    @State private var isSearching = false
    @State private var didSearch = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Search Podcasts").font(.title2.weight(.semibold))
            Text("Choose a show, then subscribe to its publisher’s feed.").foregroundStyle(.secondary)
            HStack(spacing: 10) {
                TextField("Podcast title or author", text: $query).textFieldStyle(.roundedBorder).onSubmit(search)
                Button("Search", action: search).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            }
            Picker("Directory", selection: $provider) {
                ForEach(PodcastDirectoryProvider.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Group {
                if isSearching {
                    ProgressView("Searching \(provider.title)…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView("Could Not Search", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    ContentUnavailableView(didSearch ? "No Podcasts Found" : "Find a Podcast", systemImage: "podcasts",
                                           description: Text(didSearch ? "Try another title or author." : "Search Podcast Index or Apple Podcasts."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(results) { result in
                        HStack(spacing: 12) {
                            DirectoryArtwork(url: result.artworkURL, symbol: "podcasts").frame(width: 46, height: 46)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.title).fontWeight(.medium).lineLimit(2)
                                Text(result.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(result.feedURL.host ?? result.feedURL.absoluteString).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Button("Use Feed") { use(result) }
                        }.padding(.vertical, 5).contentShape(Rectangle()).onTapGesture(count: 2) { use(result) }
                    }.listStyle(.inset)
                }
            }
            HStack {
                Link(provider.title, destination: URL(string: provider == .podcastIndex ? "https://podcastindex.org" : "https://podcasts.apple.com")!)
                    .font(.caption)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 650, height: 590)
            .onChange(of: provider) { _, _ in
                searchTask?.cancel(); requestID = UUID(); results = []; errorMessage = nil; didSearch = false; isSearching = false
            }
            .onDisappear { searchTask?.cancel(); requestID = UUID() }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        searchTask?.cancel()
        let id = UUID(), directory = provider
        requestID = id; isSearching = true; errorMessage = nil; didSearch = true
        searchTask = Task { @MainActor in
            defer { if requestID == id { isSearching = false } }
            do {
                let found = try await client.search(query: term, provider: directory)
                guard !Task.isCancelled, requestID == id else { return }
                results = found
            } catch is CancellationError { }
            catch { if !Task.isCancelled, requestID == id { errorMessage = error.localizedDescription } }
        }
    }

    private func use(_ result: PodcastDirectoryResult) { choose(result); dismiss() }
}

struct RadioDiscoverySheet: View {
    @Bindable var controller: RadioController
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchTask: Task<Void, Never>?
    @State private var didSearch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Discover Internet Radio").font(.title2.weight(.semibold))
            HStack {
                TextField("Station name", text: $controller.query).textFieldStyle(.roundedBorder).onSubmit(search)
                Button("Search", action: search).disabled(controller.isSearching)
            }
            HStack(spacing: 10) {
                TextField("Country", text: $controller.country)
                TextField("Language", text: $controller.language)
                TextField("Tags", text: $controller.tags)
            }.textFieldStyle(.roundedBorder).onSubmit(search)
            Group {
                if controller.isSearching {
                    ProgressView("Searching Radio Browser…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if controller.results.isEmpty {
                    ContentUnavailableView(didSearch ? "No Stations Found" : "Find a Station", systemImage: "antenna.radiowaves.left.and.right",
                                           description: Text(didSearch ? "Try another name, country, language, or tag." : "Search the community Radio Browser directory."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(controller.results) { station in
                        HStack(spacing: 12) {
                            RadioStationLabel(station: station, favoriteOverride: controller.stations.first(where: { $0.id == station.id })?.isFavorite)
                            Spacer(minLength: 8)
                            Button { Task { await controller.saveFavorite(station) } } label: {
                                Image(systemName: controller.stations.contains(where: { $0.id == station.id && $0.isFavorite }) ? "star.fill" : "star")
                            }.help("Save station to Favorites").accessibilityLabel("Save \(station.title) to Favorites")
                            Button("Play") { Task { await controller.addToPlaylist(station, playNow: true) } }.disabled(station.isHLS)
                        }.padding(.vertical, 4).contextMenu {
                            RadioStationActions(controller: controller, station: station)
                        }
                    }.listStyle(.inset)
                }
            }
            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Link("Radio Browser", destination: URL(string: "https://www.radio-browser.info")!).font(.caption)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 700, height: 610)
            .onAppear { model.radioDiscoveryOwnsCertificates = true }
            .onDisappear {
                searchTask?.cancel(); controller.cancelSearch()
                model.radioDiscoveryOwnsCertificates = false
                if model.certificatePrompts.first?.challenge.sourceID == RadioLibrary.sourceID { model.answerCertificate(false) }
            }
            .sheet(isPresented: Binding(get: { model.radioDiscoveryOwnsCertificates && !model.certificatePrompts.isEmpty }, set: { if !$0 && model.radioDiscoveryOwnsCertificates { model.answerCertificate(false) } })) {
                if let prompt = model.certificatePrompts.first { CertificateSheet(prompt: prompt, answer: model.answerCertificate) }
            }
    }

    private func search() {
        searchTask?.cancel(); didSearch = true
        searchTask = Task { await controller.search() }
    }
}

struct DirectoryArtwork: View {
    let url: URL?
    let symbol: String
    var body: some View {
        Rectangle().fill(.quaternary).overlay {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFit() }
                else { Image(systemName: symbol).resizable().scaledToFit().foregroundStyle(.tertiary).padding(10) }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 5)).accessibilityHidden(true)
    }
}
