import AppKit
import KeyboardShortcuts
import MacarokCore
import SwiftUI

enum SettingsTab: Hashable { case general, playback, shortcuts, sources, scrobbling }

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var selectedTab: SettingsTab
    @State private var removal: SourceRecord?
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
            Group {
                if let controller = model.scrobbling { ScrobblingSettingsView(controller: controller, sources: model.sources) }
                else { ContentUnavailableView("Scrobbling", systemImage: "waveform", description: Text("Open a library to configure Last.fm.")) }
            }.tag(SettingsTab.scrobbling).tabItem { Label("Scrobbling", systemImage: "waveform") }
        }
        .frame(width: 650, height: 555)
        .confirmationDialog("Remove \(removal?.name ?? "Source")?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Remove Source", role: .destructive) { if let removal { model.removeSource(removal) }; removal = nil }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text("This removes its library entries and queued tracks from Macarok. Your audio files remain in place.")
        }
        .sheet(item: $credentialSource) { CredentialEditor(source: $0, model: model) }
        .sheet(isPresented: Binding(get: { model.addSourcePresenter == .settings }, set: { if !$0 && model.addSourcePresenter == .settings { model.addSourcePresenter = nil } })) { AddSourceSheet(model: model) }
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
                Text("Double-clicking an entry in the active playlist always plays that entry.").font(.caption).foregroundStyle(.secondary)
                Text("Double-clicking an album or artist always adds all its tracks to the active playlist.").font(.caption).foregroundStyle(.secondary)
                Text("Double-clicking music starts playback when the active playlist is empty.").font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Macarok", value: "0.1.0 · Private Beta")
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
                Text("Original-quality audio is requested whenever the source provides it.").font(.caption).foregroundStyle(.secondary)
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
                Text("Media keys follow macOS’s active player. In-app shortcuts apply while Macarok is focused.").font(.caption).foregroundStyle(.secondary)
                Text("Left and Right seek by 5 seconds. Hold either key to continue seeking. Text editing keeps its usual arrow keys.").font(.caption).foregroundStyle(.secondary)
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
        VStack(spacing: 0) {
            HStack {
                Text("Music Sources").font(.headline)
                Spacer()
                Button("Add Source…", systemImage: "plus") { model.presentAddSource(from: .settings) }
                    .accessibilityIdentifier("settingsAddSource")
            }.padding(.horizontal, 20).frame(height: 48).background(.bar)
            Divider()
            Form {
                if model.sources.isEmpty {
                    Section { ContentUnavailableView("No Sources", systemImage: "externaldrive", description: Text("Add a folder, OpenSubsonic server, or podcast.")) }
                }
                ForEach(model.sources) { source in
                    Section {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: source.kind.librarySymbol)
                                .font(.title3).foregroundStyle(Color.accentColor).frame(width: 25)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name).fontWeight(.medium)
                                Text(source.location).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                                Text(source.kind.displayName).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { removal = source } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove source")
                        }
                        if source.kind == .openSubsonic {
                            HStack {
                                Button("Edit Credentials…") { credentialSource = source }
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
            }.formStyle(.grouped).id(trustVersion)
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
            model.status = "Credentials updated for “\(source.name)”."; dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
