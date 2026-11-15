import MacarokCore
import SwiftUI

enum SourceCatalogKind: String, CaseIterable, Identifiable {
    case local, openSubsonic, bandcamp, radio, podcasts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: "Local Files"
        case .openSubsonic: "OpenSubsonic"
        case .bandcamp: "Bandcamp"
        case .radio: "Internet Radio"
        case .podcasts: "Podcasts"
        }
    }
    var symbol: String {
        switch self {
        case .local: "folder"
        case .openSubsonic: "server.rack"
        case .bandcamp: "music.note"
        case .radio: "antenna.radiowaves.left.and.right"
        case .podcasts: "podcasts"
        }
    }
    var isServer: Bool { self == .openSubsonic || self == .bandcamp }
}

struct AddSourceSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind: SourceCatalogKind = .local
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var useAPIKey = false
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var connectionTask: Task<Void, Never>?
    @State private var presentedCertificateIDs: Set<UUID> = []
    @State private var showsPodcastSearch = false
    @State private var showsRadioSearch = false

    init(model: AppModel, initialKind: SourceCatalogKind = .local) {
        self.model = model
        _kind = State(initialValue: initialKind)
        if initialKind == .bandcamp {
            _name = State(initialValue: "Bandcamp")
            _address = State(initialValue: "https://bandcamp.com/api/subsonic")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "music.note.house").font(.system(size: 28)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add a Music Source").font(.title2.weight(.semibold))
                    Text("Browse sources together or choose an individual library.").font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("MUSIC SOURCES").font(.caption2.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.bottom, 4)
                    ForEach(SourceCatalogKind.allCases) { item in
                        Button { kind = item } label: {
                            Label(item.title, systemImage: item.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                                .background(kind == item ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("sourceCatalog-\(item.rawValue)")
                    }
                    Spacer()
                    Text("Accounts and subscriptions stay with each service.")
                        .font(.caption).foregroundStyle(.secondary).padding(9)
                }.frame(width: 175).padding(.trailing, 16).disabled(isConnecting)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        Label(kind.title, systemImage: kind.symbol).font(.title3.weight(.semibold))
                        Group {
                            switch kind {
                            case .local: localForm
                            case .openSubsonic, .bandcamp: serverForm
                            case .radio: radioForm
                            case .podcasts: podcastForm
                            }
                        }.disabled(isConnecting)
                        Divider().padding(.top, 8)
                        serviceInformation
                    }.padding(.leading, 20).padding(.trailing, 2)
                }
            }.frame(maxHeight: .infinity)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sourceConnectionError")
            }
            if isConnecting {
                HStack(spacing: 9) { ProgressView().controlSize(.small); Text(kind == .podcasts ? "Reading the podcast feed…" : kind == .radio ? "Adding the radio station…" : "Connecting to the music server…").foregroundStyle(.secondary) }
            }

            Spacer(minLength: 0)
            Divider()
            HStack(alignment: .center) {
                Spacer()
                Button("Cancel") { connectionTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(kind == .local ? "Choose Folder…" : kind == .podcasts ? "Subscribe" : kind == .radio ? "Add Station" : "Connect") { connect() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(isConnecting || (kind != .local && !validAddress) || (kind.isServer && !validCredentials) || (kind == .radio && model.radio == nil))
                    .accessibilityIdentifier("confirmAddSource")
            }
        }
        .padding(24).frame(width: 790, height: 650)
        .onChange(of: kind) { _, value in
            errorMessage = nil
            if value == .bandcamp { name = "Bandcamp"; address = "https://bandcamp.com/api/subsonic"; useAPIKey = false }
            else if address == "https://bandcamp.com/api/subsonic" { name = ""; address = "" }
        }
        .onDisappear { connectionTask?.cancel(); rejectOwnedCertificatePrompts() }
        .interactiveDismissDisabled(isConnecting)
        .sheet(isPresented: Binding(get: { !model.radioDiscoveryOwnsCertificates && !model.certificatePrompts.isEmpty }, set: { if !$0 && !model.radioDiscoveryOwnsCertificates { rejectOwnedCertificatePrompts() } })) {
            if let prompt = model.certificatePrompts.first {
                CertificateSheet(prompt: prompt, answer: model.answerCertificate)
                    .onAppear { presentedCertificateIDs.insert(prompt.id) }
            }
        }
        .sheet(isPresented: $showsPodcastSearch) {
            PodcastDiscoverySheet { result in address = result.feedURL.absoluteString }
        }
        .sheet(isPresented: $showsRadioSearch) {
            if let controller = model.radio { RadioDiscoverySheet(controller: controller, model: model) }
        }
    }

    private var localForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Choose the folder that contains your music.", systemImage: "folder.badge.plus").font(.headline)
            Text("Macarok indexes its albums and tracks, including CUE sheets. Your files stay in their current location.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("MP3 · FLAC · Ogg Vorbis · Opus · AAC · ALAC · WAV · AIFF")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 14)
    }

    private var serverForm: some View {
        VStack(alignment: .leading, spacing: 12) {
          if kind == .bandcamp {
              Text("Connect your purchased music using Bandcamp’s Subsonic endpoint. Generate a Subsonic username and password in your Bandcamp account settings, then paste them below.")
                  .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              HStack {
                  Link("Open Bandcamp Settings", destination: URL(string: "https://bandcamp.com/settings#fan")!)
                  Link("How to Connect", destination: URL(string: "https://blog.bandcamp.com/2026/07/16/discover-improvements-and-subsonic-implementation/")!)
              }.font(.callout)
          }
          Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow { Text("Name"); TextField("Name", text: $name, prompt: Text("Home Music")) }
            GridRow {
                Text("Server URL")
                TextField("Server URL", text: $address, prompt: Text("https://music.example.com"))
                    .textContentType(.URL).autocorrectionDisabled().accessibilityIdentifier("serverAddress")
            }
            if kind != .bandcamp {
              GridRow {
                Text("Authentication")
                Picker("Authentication", selection: $useAPIKey) {
                    Text("Username & Password").tag(false)
                    Text("API Key").tag(true)
                }.labelsHidden()
              }
            }
            if useAPIKey {
                GridRow { Text("API Key"); SecureField("API Key", text: $apiKey) }
            } else {
                GridRow { Text("Username"); TextField("Username", text: $username).textContentType(.username).autocorrectionDisabled() }
                GridRow { Text("Password"); SecureField("Password", text: $password).textContentType(.password) }
            }
          }.textFieldStyle(.roundedBorder)
          if useAPIKey { Text("Use an API key only if your server supports OpenSubsonic API-key authentication.").font(.caption).foregroundStyle(.secondary) }
          Text("HTTP and HTTPS servers are supported. Self-signed certificates can be trusted for this server when connecting.")
              .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          Text("Enter the server base URL. Keep credentials in the fields above; URL queries and fragments are not supported.")
              .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var radioForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Save a station stream URL or find a station in the Radio Browser directory.").foregroundStyle(.secondary)
            TextField("Station name", text: $name)
            TextField("Stream URL", text: $address, prompt: Text("https://example.com/live.mp3")).textContentType(.URL).autocorrectionDisabled()
            Button { showsRadioSearch = true } label: { Label("Browse Radio Stations…", systemImage: "magnifyingglass") }
                .disabled(model.radio == nil)
            Text("Live stations are saved separately from your music albums and tracks.").font(.caption).foregroundStyle(.secondary)
        }.textFieldStyle(.roundedBorder)
    }

    private var serviceInformation: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Other Music Services").font(.headline)
            Text("Playback from these services is not available in Macarok.").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                serviceCard("Qobuz", detail: "Full playback requires an approved partner integration.", url: "https://www.qobuz.com/ca-en/page/annonceurs-partenariats")
                serviceCard("Deezer", detail: "A public full-playback integration route is not currently confirmed.", url: "https://en.deezercommunity.com/features-feedback-44/apis-to-enable-3rd-party-apps-ndk-not-available-javascript-sdk-not-working-76108?sort=mostLiked")
                serviceCard("Spotify", detail: "Spotify’s developer policy restricts integration into multi-service music players.", url: "https://developer.spotify.com/policy")
            }
        }
    }

    private func serviceCard(_ title: String, detail: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).fontWeight(.medium)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("Official Information ↗", destination: URL(string: url)!).font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
    }

    private var podcastForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            TextField("Feed URL", text: $address, prompt: Text("https://example.com/podcast.rss"))
                .textContentType(.URL).autocorrectionDisabled().textFieldStyle(.roundedBorder)
            Text("Paste an RSS or Atom feed URL. Macarok will read the show information, artwork, and available episodes.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { showsPodcastSearch = true } label: { Label("Search Podcasts…", systemImage: "magnifyingglass") }
        }
    }


    private var normalizedAddress: String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("://") ? trimmed : "https://" + trimmed
    }
    private var validAddress: Bool {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: normalizedAddress), let host = url.host, !host.isEmpty else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.user == nil && url.password == nil
            && (!kind.isServer || (url.query == nil && url.fragment == nil))
    }
    private var validCredentials: Bool {
        useAPIKey ? !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func rejectOwnedCertificatePrompts() {
        let host = URL(string: normalizedAddress)?.host?.lowercased()
        let knownSourceIDs = Set(model.sources.map(\.id))
        let owned = model.certificatePrompts.filter { prompt in
            presentedCertificateIDs.contains(prompt.id)
                || (isConnecting && prompt.challenge.host.lowercased() == host && !knownSourceIDs.contains(prompt.challenge.sourceID))
        }
        let ids = Set(owned.map(\.id))
        model.certificatePrompts.removeAll { ids.contains($0.id) }
        for prompt in owned { prompt.completion(false) }
    }

    private func connect() {
        if kind == .local { model.pickFolder(); dismiss(); return }
        isConnecting = true; errorMessage = nil
        connectionTask = Task { @MainActor in
            defer { isConnecting = false }
            do {
                if kind == .podcasts { try await model.addPodcast(address: normalizedAddress) }
                else if kind == .radio {
                    guard let controller = model.radio else { return }
                    await controller.addURL(name: name.trimmingCharacters(in: .whitespacesAndNewlines), address: normalizedAddress)
                    if let detail = controller.errorMessage { errorMessage = detail; return }
                }
                else {
                    let credentials = useAPIKey ? SourceCredentials(apiKey: apiKey) : SourceCredentials(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
                    try await model.addServer(name: name.trimmingCharacters(in: .whitespacesAndNewlines), address: normalizedAddress, credentials: credentials)
                }
                if !Task.isCancelled { dismiss() }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
}
