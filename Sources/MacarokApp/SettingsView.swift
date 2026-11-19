import AppKit
import KeyboardShortcuts
import MacarokCore
import SwiftUI

enum SettingsTab: Hashable { case general, playback, shortcuts, sources, podcasts, scrobbling }

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var selectedTab: SettingsTab
    @State private var removal: SourceRecord?
    @State private var confirmsPodcastsRemoval = false
    @State private var credentialSource: SourceRecord?
    @State private var trustVersion = 0
    @State private var rejectedShortcutKeys: Set<String> = []

    init(model: AppModel, initialTab: SettingsTab = .general) {
        self.model = model
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            general.tag(SettingsTab.general).tabItem { Label("General", systemImage: "gearshape") }
            playback.tag(SettingsTab.playback).tabItem { Label("Playback", systemImage: "play.circle") }
            shortcuts.tag(SettingsTab.shortcuts).tabItem { Label("Shortcuts", systemImage: "keyboard") }
            sources.tag(SettingsTab.sources).tabItem { Label("Sources", systemImage: "externaldrive.connected.to.line.below") }
            PodcastSettingsView(model: model, podcasts: model.podcasts).tag(SettingsTab.podcasts).tabItem { Label { Text("Podcasts") } icon: { Image(nsImage: PodcastSourceIcon.settingsImage).renderingMode(.template) } }
            ServicesSettingsView(model: model).tag(SettingsTab.scrobbling).tabItem { Label("Services", systemImage: "network") }
        }
        .frame(width: 650, height: 555)
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
        .confirmationDialog("Remove \(removal?.name ?? "Source")?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Remove Source", role: .destructive) { if let removal { model.removeSource(removal) }; removal = nil }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text("This removes its library entries and queued tracks from Macarok. Your audio files remain in place.")
        }
        .sheet(item: $credentialSource) { CredentialEditor(source: $0, model: model) }
        .sheet(isPresented: Binding(get: { model.addSourcePresenter == .settings }, set: { if !$0 && model.addSourcePresenter == .settings { model.addSourcePresenter = nil } })) { AddSourceSheet(model: model) }
    }

    private var applicationVersion: String {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else { return "Development" }
        return version
    }

    private var general: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $model.settings.appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Text("System follows the appearance selected in macOS.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Library") {
                Picker("Track double-click", selection: $model.settings.trackDoubleClickAction) {
                    ForEach(TrackDoubleClickAction.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Active Playlist") {
                Toggle("Show album groups", isOn: $model.settings.playlistAlbumGroups)
                Text("Adjacent tracks from the same album appear under one header with its artwork.").font(.caption).foregroundStyle(.secondary)
                Toggle("Show sources", isOn: $model.settings.playlistShowsSources)
                Text("When browsing All Sources, each entry or album header names its source.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Center Panel") {
                LabeledContent("Show Playing automatically") {
                    PlayingAutoSwitchModePicker(selection: $model.settings.playingAutoSwitchMode)
                        .fixedSize()
                }
            }
            Section("Menu Bar") {
                Toggle("Show Macarok in the menu bar", isOn: $model.settings.showMenuBar)
            }
            Section("About") {
                LabeledContent("Macarok", value: applicationVersion)
                LabeledContent("Audio engine", value: "libVLC 4")
                Link("Project on GitHub", destination: URL(string: "https://github.com/armateurlabs/macarok")!)
            }
        }.formStyle(.grouped)
    }

    private var playback: some View {
        Form {
            Section("Streaming") {
                Picker("Streaming buffer", selection: $model.settings.customBuffer) {
                    Text("Automatic").tag(false)
                    Text("Custom").tag(true)
                }
                if model.settings.customBuffer {
                    HStack {
                        Text("Target buffer duration")
                        Spacer()
                        TextField("Seconds", value: $model.settings.bufferSeconds, format: .number.precision(.fractionLength(0)))
                            .multilineTextAlignment(.trailing).frame(width: 65)
                        Stepper("Seconds", value: $model.settings.bufferSeconds, in: 1...120, step: 1).labelsHidden()
                        Text("seconds").foregroundStyle(.secondary)
                    }
                    Text("Target duration: 1–120 seconds. Changes apply to the next streamed track.").font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Streaming quality", value: "Original")
                Picker("Internet Archive quality", selection: $model.settings.archiveQuality) {
                    ForEach(ArchiveAudioQuality.allCases) { Text($0.title).tag($0) }
                }
                Text("High streams lossless FLAC when a recording shares it, otherwise the best MP3. Standard uses smaller MP3 files. Changing it refreshes Internet Archive sources.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Playback") {
                HStack {
                    Text("Repeat")
                    Spacer()
                    Button { model.cycleRepeat() } label: {
                        Label(model.settings.repeatMode.title, systemImage: model.settings.repeatMode.symbol).frame(minWidth: 85)
                    }.help("Next: \(model.settings.repeatMode.next.title)")
                }
            }
            if let controller = model.podcastDownloads {
                Section("Podcast and Audiobook Downloads") {
                    Text("Episodes and LibriVox chapters download only when you choose to download them. Completed files stay until you remove them; removed episodes move to Trash. Unfinished transfers are cleaned up automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(controller.directory.path).font(.caption).textSelection(.enabled)
                    Button("Open Downloads Folder…", action: controller.openFolder)
                    ForEach(controller.downloads.values.sorted { $0.downloadedAt > $1.downloadedAt }) { download in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(download.title).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: download.byteCount, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Reveal") { controller.reveal(download) }
                            Button("Remove", role: .destructive) { controller.remove(download) }.disabled(!controller.canRemove(download))
                        }
                    }
                }
            }
        }.formStyle(.grouped)
        .onChange(of: model.settings.bufferSeconds) { _, value in
            if !value.isFinite { model.settings.bufferSeconds = 20 }
            else { model.settings.bufferSeconds = min(120, max(1, value)) }
        }
    }

    private var shortcuts: some View {
        Form {
            Section {
                LabeledContent("Mac media keys", value: "Play / Pause · Previous · Next")
            }
            Section("In App") {
                localRecorder("Play / Pause", key: "playPause", fallback: .init(.space))
                localRecorder("Next Track", key: "nextTrack", fallback: .init(.rightArrow, modifiers: [.command]))
                localRecorder("Previous Track", key: "previousTrack", fallback: .init(.leftArrow, modifiers: [.command]))
                localRecorder("Add to Playlist", key: "addToPlaylist", fallback: .init(.return, modifiers: [.command]))
                localRecorder("Search Library", key: "search", fallback: .init(.f, modifiers: [.command]))
                localRecorder("Show Current Track", key: "showCurrentTrack", fallback: .init(.l, modifiers: [.command]))
                Button("Restore In-App Defaults") { model.settings.localShortcuts = [:] }
            }
            Section("Global") {
                KeyboardShortcuts.Recorder("Play / Pause", name: .playPause)
                KeyboardShortcuts.Recorder("Next Track", name: .nextTrack)
                KeyboardShortcuts.Recorder("Previous Track", name: .previousTrack)
                KeyboardShortcuts.Recorder("Show Macarok", name: .showMacarok)
                Text("Choose a combination to enable a global shortcut. Clear it to disable it.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func localRecorder(_ title: String, key: String, fallback: KeyboardShortcuts.Shortcut) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 4) {
            KeyboardShortcuts.Recorder(shortcut: Binding(get: {
                guard let data = model.settings.localShortcuts[key] else { return fallback }
                return (try? JSONDecoder().decode(KeyboardShortcuts.Shortcut?.self, from: data)) ?? nil
            }, set: { shortcut in
                if let shortcut, model.isReservedArrowShortcut(shortcut) { rejectedShortcutKeys.insert(key); return }
                rejectedShortcutKeys.remove(key)
                if let data = try? JSONEncoder().encode(shortcut) { model.settings.localShortcuts[key] = data }
            }))
                if rejectedShortcutKeys.contains(key) || model.localShortcut(key).map({ model.isReservedArrowShortcut($0) }) == true {
                    Text("Left and Right are reserved for seeking. Choose another shortcut.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var sources: some View {
        let music = model.sources.filter { $0.kind == .local || $0.kind == .openSubsonic }
        let radio = model.sources.filter { $0.kind == .radio }
        let podcasts = model.sources.filter(\.kind.isPodcast)
        let archives = model.sources.filter { $0.kind == .internetArchive }
        let missingDefaults = DefaultSource.allCases.filter { value in !model.sources.contains { DefaultSource($0) == value } }
        return VStack(spacing: 0) {
            HStack {
                Text("Sources").font(.headline)
                Spacer()
                if !missingDefaults.isEmpty {
                    Button("Restore Default Sources") { model.restoreDefaultSources() }
                        .help("Adds back \(missingDefaults.map(\.record.name).formatted(.list(type: .and))).")
                }
                Button("Add Source…", systemImage: "plus") { model.presentAddSource(from: .settings) }
                    .accessibilityIdentifier("settingsAddSource")
            }.padding(.horizontal, 20).frame(height: 48).background(.bar)
            Divider()
            Form {
                if model.sources.isEmpty {
                    Section { ContentUnavailableView("No Sources", systemImage: "externaldrive", description: Text("Add a folder, OpenSubsonic server, podcast, or Internet Archive collection.")) }
                }
                if !music.isEmpty {
                    Section("Music") { ForEach(music) { sourceRow($0) } }
                }
                if !radio.isEmpty {
                    Section("Internet Radio") { ForEach(radio) { sourceRow($0) } }
                }
                if !podcasts.isEmpty {
                    Section("Podcasts") { podcastsRow(podcasts) }
                }
                if !archives.isEmpty {
                    Section("Internet Archive") { ForEach(archives) { sourceRow($0) } }
                }
            }.formStyle(.grouped).id(trustVersion)
        }
        .confirmationDialog("Remove Podcasts?", isPresented: $confirmsPodcastsRemoval, titleVisibility: .visible) {
            Button("Remove Podcasts", role: .destructive) { model.removePodcasts() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let shows = podcasts.filter { $0.kind == .podcasts }.count
            Text(shows == 0 ? "The podcast directory leaves the source list. Restore Default Sources brings it back."
                 : "This also unsubscribes from \(shows == 1 ? "1 show" : "\(shows) shows") and removes downloaded episodes from Macarok.")
        }
    }

    private func sourceIcon(_ kind: SourceKind) -> some View {
        Group {
            if kind.isPodcast { Image.podcast } else { Image(systemName: kind.librarySymbol) }
        }
        .font(.title3).foregroundStyle(kind.isPodcast ? Color.primary : Color.accentColor).frame(width: 25)
    }

    private func sourceRow(_ source: SourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                sourceIcon(source.kind)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(source.name).fontWeight(.medium)
                        if DefaultSource(source) != nil {
                            Text("Default").font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    if !source.location.isEmpty {
                        Text(source.location).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                    if source.kind == .local || source.kind == .openSubsonic {
                        Text(source.kind.displayName).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(role: .destructive) { removal = source } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove source")
            }
            if source.kind == .openSubsonic {
                HStack {
                    Button("Edit Credentials…") { credentialSource = source }
                    if model.serverScan?.sourceID == source.id {
                        ProgressView().controlSize(.small)
                        Text(model.serverScan?.count.map { "\($0.formatted()) files" } ?? "Scanning…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Scan Library on Server") { model.scanServerLibrary([source]) }
                            .disabled(model.serverScan != nil || model.isRefreshing)
                            .help("Asks the server to look for new files, then refreshes this source. Requires an administrator account.")
                    }
                    Spacer()
                    if let url = source.url, let host = url.host, url.scheme?.lowercased() == "https" {
                        let fingerprint = CertificateTrustStore.shared.trustedFingerprint(sourceID: source.id, host: host, port: url.port ?? 443)
                        if fingerprint != nil {
                            Button("Forget Certificate Trust") {
                                CertificateTrustStore.shared.revoke(sourceID: source.id, host: host, port: url.port ?? 443)
                                trustVersion += 1
                            }.help("The server will ask for trust on its next new connection.")
                        } else { Label("macOS certificate validation", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    /// Subscribed shows are managed in the Podcasts tab, so they stay one readable row here.
    private func podcastsRow(_ podcasts: [SourceRecord]) -> some View {
        let shows = podcasts.filter { $0.kind == .podcasts }.count
        return HStack(alignment: .top, spacing: 12) {
            sourceIcon(.podcastDirectory)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Podcasts").fontWeight(.medium)
                    if podcasts.contains(where: { $0.kind == .podcastDirectory }) {
                        Text("Default").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text("Apple Podcasts directory · \(shows == 1 ? "1 subscribed show" : "\(shows) subscribed shows")")
                    .font(.caption).foregroundStyle(.secondary)
                if shows > 0 {
                    Button("Manage Subscriptions…") { selectedTab = .podcasts }.font(.caption).buttonStyle(.link)
                }
            }
            Spacer()
            Button(role: .destructive) { confirmsPodcastsRemoval = true } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove Podcasts")
        }
    }
}

private struct PlayingAutoSwitchModePicker: NSViewRepresentable {
    @Binding var selection: PlayingAutoSwitchMode

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.addItems(withTitles: PlayingAutoSwitchMode.allCases.map(\.title))
        picker.selectItem(withTitle: selection.title)
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.select(_:))
        picker.setAccessibilityLabel("Show Playing automatically")
        picker.setAccessibilityIdentifier("playingAutoSwitchModePicker")
        return picker
    }

    func updateNSView(_ picker: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        picker.selectItem(withTitle: selection.title)
    }

    final class Coordinator: NSObject {
        var selection: Binding<PlayingAutoSwitchMode>
        init(selection: Binding<PlayingAutoSwitchMode>) { self.selection = selection }

        @objc func select(_ sender: NSPopUpButton) {
            guard let title = sender.selectedItem?.title,
                  let mode = PlayingAutoSwitchMode.allCases.first(where: { $0.title == title }) else { return }
            selection.wrappedValue = mode
        }
    }
}

private struct CredentialEditor: View {
    let source: SourceRecord
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var useAPIKey = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Credentials for \(source.name)").font(.title3.weight(.semibold))
            Form {
                Picker("Authentication", selection: $useAPIKey) { Text("Username & Password").tag(false); Text("API Key").tag(true) }
                if useAPIKey { SecureField("API Key", text: $apiKey) }
                else { TextField("Username", text: $username); SecureField("Password", text: $password) }
            }
            Text("Credentials are stored in your macOS Keychain. Changes apply to new requests.").font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Save") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(useAPIKey ? apiKey.isEmpty : username.isEmpty) }
        }.padding(24).frame(width: 470)
        .task {
            do {
                if let credentials = try KeychainCredentialStore.shared.load(sourceID: source.id) {
                    username = credentials.username; password = credentials.password; apiKey = credentials.apiKey ?? ""; useAPIKey = credentials.apiKey != nil
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func save() {
        do {
            try KeychainCredentialStore.shared.save(useAPIKey ? SourceCredentials(apiKey: apiKey) : SourceCredentials(username: username, password: password), sourceID: source.id)
            model.invalidateSourceClient(source.id)
            model.status = "Credentials updated for “\(source.name)”."; dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
