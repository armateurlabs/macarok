import MacarokCore
import SwiftUI

struct AddSourceSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind: SourceKind = .local
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var useAPIKey = false
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var connectionTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "music.note.house").font(.system(size: 28)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add a Music Source").font(.title2.weight(.semibold))
                    Text("Each source keeps its own library, search, and listening history.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Picker("Source", selection: $kind) {
                Label("Local Files", systemImage: "folder").tag(SourceKind.local)
                Label("OpenSubsonic", systemImage: "server.rack").tag(SourceKind.openSubsonic)
                Label("Podcast", systemImage: "mic").tag(SourceKind.podcasts)
            }.pickerStyle(.segmented).disabled(isConnecting)

            Group {
                switch kind {
                case .local: localForm
                case .openSubsonic: serverForm
                case .podcasts: podcastForm
                }
            }.disabled(isConnecting)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sourceConnectionError")
            }
            if isConnecting {
                HStack(spacing: 9) { ProgressView().controlSize(.small); Text(kind == .podcasts ? "Reading the podcast feed…" : "Connecting to the music server…").foregroundStyle(.secondary) }
            }

            Spacer(minLength: 0)
            Divider()
            HStack(alignment: .center) {
                Menu("More services") {
                    Text("Future sources")
                    Button("Spotify", action: {}).disabled(true)
                    Button("Qobuz", action: {}).disabled(true)
                    Button("Deezer", action: {}).disabled(true)
                    Button("Bandcamp", action: {}).disabled(true)
                    Divider()
                    Button("Cloud Storage · Under Study", action: {}).disabled(true)
                }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { connectionTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(kind == .local ? "Choose Folder…" : kind == .podcasts ? "Subscribe" : "Connect") { connect() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(isConnecting || (kind != .local && !validAddress) || (kind == .openSubsonic && !validCredentials))
                    .accessibilityIdentifier("confirmAddSource")
            }
        }
        .padding(24).frame(width: 570, height: kind == .openSubsonic ? 500 : 390)
        .onChange(of: kind) { _, _ in errorMessage = nil }
        .onDisappear { connectionTask?.cancel() }
        .interactiveDismissDisabled(isConnecting)
        .sheet(isPresented: Binding(get: { !model.certificatePrompts.isEmpty }, set: { if !$0 { model.answerCertificate(false) } })) {
            if let prompt = model.certificatePrompts.first { CertificateSheet(prompt: prompt, answer: model.answerCertificate) }
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
        Form {
            TextField("Name", text: $name, prompt: Text("Home Music"))
            TextField("Server URL", text: $address, prompt: Text("https://music.example.com"))
                .textContentType(.URL).autocorrectionDisabled()
                .accessibilityIdentifier("serverAddress")
            Picker("Authentication", selection: $useAPIKey) {
                Text("Username & Password").tag(false)
                Text("API Key").tag(true)
            }
            if useAPIKey {
                SecureField("API Key", text: $apiKey)
                Text("Use an API key only if your server supports OpenSubsonic API-key authentication.").font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("Username", text: $username).textContentType(.username).autocorrectionDisabled()
                SecureField("Password", text: $password).textContentType(.password)
            }
            Text("HTTP and HTTPS servers are supported. Self-signed certificates can be trusted for this server when connecting.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Enter the server base URL. Keep credentials in the fields above; URL queries and fragments are not supported.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }

    private var podcastForm: some View {
        Form {
            TextField("Feed URL", text: $address, prompt: Text("https://example.com/podcast.rss"))
                .textContentType(.URL).autocorrectionDisabled()
            Text("Paste an RSS or Atom feed URL. Macarok will read the show information, artwork, and available episodes.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }

    private var normalizedAddress: String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("://") ? trimmed : "https://" + trimmed
    }
    private var validAddress: Bool {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: normalizedAddress), let host = url.host, !host.isEmpty else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.user == nil && url.password == nil
            && (kind != .openSubsonic || (url.query == nil && url.fragment == nil))
    }
    private var validCredentials: Bool {
        useAPIKey ? !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func connect() {
        if kind == .local { model.pickFolder(); dismiss(); return }
        isConnecting = true; errorMessage = nil
        connectionTask = Task { @MainActor in
            defer { isConnecting = false }
            do {
                if kind == .podcasts { try await model.addPodcast(address: normalizedAddress) }
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
