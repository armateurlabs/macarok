import MacarokCore
import SwiftUI

/// Online services, one row each like Sources: what they do, their state, and their own settings in a sheet.
struct ServicesSettingsView: View {
    @Bindable var model: AppModel
    @State private var editing: Service?

    enum Service: String, Identifiable {
        case lastFM, youtube
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Services").font(.headline)
                Spacer()
            }.padding(.horizontal, 20).frame(height: 48).background(.bar)
            Divider()
            if let scrobbling = model.scrobbling, let links = model.songLinks {
                Form {
                    Section("Accounts and Keys") {
                        row(symbol: "waveform", name: "Last.fm", purpose: "Scrobbling and similar tracks",
                            status: Self.lastFMStatus(scrobbling), configured: scrobbling.username != nil) { editing = .lastFM }
                        row(symbol: "play.rectangle", name: "YouTube", purpose: "Song videos in the YouTube tab",
                            status: links.hasAPIKey ? "Personal API key saved" : "No API key: MusicBrainz links and YouTube search",
                            configured: links.hasAPIKey) { editing = .youtube }
                    }
                    Section {
                        info(symbol: "book", name: "Wikipedia", purpose: "Artist and album pages, links in shared songs")
                        info(symbol: "music.note.list", name: "MusicBrainz and Cover Art Archive", purpose: "Album details, artwork, and YouTube links")
                        info(symbol: "text.quote", name: "LRCLIB", purpose: "Lyrics")
                        info(symbol: "sparkles", name: "ListenBrainz", purpose: "Similar artists for mixes")
                    } header: { Text("Without an Account") } footer: {
                        Text("These services need no setup. Macarok sends them only the artist, album, or title it looks up.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .task { await scrobbling.start(); _ = await links.loadAPIKey() }
                .sheet(item: $editing) { service in
                    ServiceSheet(title: service == .lastFM ? "Last.fm" : "YouTube", done: { editing = nil }) {
                        switch service {
                        case .lastFM: ScrobblingSettingsView(controller: scrobbling, sources: model.sources).frame(width: 560, height: 500)
                        case .youtube: Form { YouTubeSettingsSection(links: links) }.formStyle(.grouped).frame(width: 520, height: 330)
                        }
                    }
                }
            } else {
                ContentUnavailableView("Services", systemImage: "network", description: Text("Open a library to configure Last.fm and YouTube."))
                    .frame(maxHeight: .infinity)
            }
        }
    }

    static func lastFMStatus(_ controller: ScrobblingController) -> String {
        if controller.needsReauthentication { return "Reconnect to keep scrobbling" }
        if let username = controller.username { return "Connected as \(username) · scrobbling \(controller.isEnabled ? "on" : "off")" }
        return controller.isConfigured ? "API key saved · not connected" : "Not set up"
    }

    private func row(symbol: String, name: String, purpose: String, status: String, configured: Bool, configure: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.accentColor).frame(width: 25)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name).fontWeight(.medium)
                    if configured { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                }
                Text(purpose).font(.caption).foregroundStyle(.secondary)
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Configure…", action: configure)
        }
    }

    private func info(symbol: String, name: String, purpose: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary).frame(width: 25)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).fontWeight(.medium)
                Text(purpose).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct ServiceSheet<Content: View>: View {
    let title: String
    let done: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.headline); Spacer() }.padding(.horizontal, 20).frame(height: 44).background(.bar)
            Divider()
            content()
            Divider()
            HStack { Spacer(); Button("Done", action: done).keyboardShortcut(.defaultAction) }.padding(12)
        }
    }
}
