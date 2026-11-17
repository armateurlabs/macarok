import MacarokCore
import SwiftUI

struct PodcastSettingsView: View {
    @Bindable var model: AppModel
    @Bindable var podcasts: PodcastController
    @State private var removal: SourceRecord?

    static let intervals: [(title: String, seconds: TimeInterval)] = [
        ("Off", 0), ("Every 15 minutes", 900), ("Every hour", 3600), ("Every 6 hours", 21_600), ("Every day", 86_400),
    ]

    private var shows: [SourceRecord] {
        model.sources.filter { $0.kind == .podcasts }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section("Refresh") {
                Picker("Check for new episodes", selection: $model.settings.podcastRefreshInterval) {
                    ForEach(Self.intervals, id: \.seconds) { Text($0.title).tag($0.seconds) }
                    if !Self.intervals.contains(where: { $0.seconds == model.settings.podcastRefreshInterval }) {
                        Text("Custom").tag(model.settings.podcastRefreshInterval)
                    }
                }
                Text("Shows refresh quietly in the background while Macarok is open. Unchanged feeds are not downloaded again.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Refresh All Now") { Task { await podcasts.refresh(sourceIDs: shows.map(\.id)) } }
                        .disabled(shows.isEmpty || podcasts.isRefreshingInBackground || model.isRefreshing)
                    if podcasts.isRefreshingInBackground { ProgressView().controlSize(.small) }
                }
            }
            Section("Shows") {
                if shows.isEmpty {
                    Text("Subscribe to a show from the Podcasts tab or Add Source.").foregroundStyle(.secondary)
                }
                ForEach(shows) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.name).lineLimit(1)
                            Text(status(source.id)).font(.caption).foregroundStyle(podcasts.shows[source.id]?.lastError == nil ? .secondary : .primary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("Unsubscribe…", role: .destructive) { removal = source }
                    }
                }
            }
        }.formStyle(.grouped)
        .confirmationDialog("Unsubscribe from \(removal?.name ?? "this show")?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Unsubscribe", role: .destructive) { if let removal { model.removeSource(removal) }; removal = nil }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text("Its episodes leave your library and playlist. Completed downloads stay until you remove them.")
        }
    }

    private func status(_ sourceID: String) -> String {
        let show = podcasts.shows[sourceID]
        if let error = show?.lastError { return "Last refresh failed: \(error)" }
        guard let refreshed = show?.refreshedAt else { return "Not refreshed since this version of Macarok" }
        return "Updated \(refreshed.formatted(date: .abbreviated, time: .shortened))"
    }
}
