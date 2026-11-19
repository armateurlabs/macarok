import MacarokCore
import SwiftUI

/// Shown below the playlist header while a dynamic mix is active.
struct SimilarMixBanner: View {
    @Bindable var model: AppModel
    @Bindable var similarity: SimilarityController
    let session: SimilarMixSession

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Similar Mix").font(.system(size: 12, weight: .semibold))
                    Text(["From \(session.title)", session.subtitle].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if session.skippedCount > 0 {
                    Text("\(session.skippedCount) skipped").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                        .help("Skipped tracks are not suggested again during this mix.")
                }
                Button("Stop Mix") { similarity.end() }.controlSize(.small)
            }
            Picker("Follow", selection: Binding(get: { model.settings.similarMixFollow },
                                                set: { model.settings.similarMixFollow = $0; similarity.followChanged() })) {
                ForEach(SimilarMixFollow.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .help("Choose whether suggestions follow the seed, the last played track, or both.")
        }
        .padding(.horizontal, 13).padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.07))
        .accessibilityIdentifier("similarMixBanner")
    }
}

/// The searching or failed state when no next track is announced yet. It is not a queue entry.
struct SimilarMixStatusRow: View {
    @Bindable var similarity: SimilarityController

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if similarity.isSearching { ProgressView().controlSize(.small) }
                else { Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary) }
            }.frame(width: 34, height: 34)
            Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(Color.accentColor).frame(width: 19)
            VStack(alignment: .leading, spacing: 2) {
                Text(similarity.isSearching ? "Finding the next track…" : "No next track").italic()
                Text(similarity.isSearching ? statusDetail : similarity.error ?? "")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !similarity.isSearching { Button("Try Again") { similarity.retry() }.controlSize(.small) }
        }
        .font(.system(size: 12)).padding(.vertical, 6).padding(.horizontal, 8)
        .modifier(SuggestionFrame(highlighted: false))
        .accessibilityIdentifier("similarMixStatus")
    }

    private var statusDetail: String {
        guard let session = similarity.session else { return "" }
        return session.skippedCount > 0 ? "Similar listening · \(session.skippedCount) skipped" : "Similar listening"
    }
}

/// Dashed accent outline marking the announced, not yet committed next track.
struct SuggestionFrame: ViewModifier {
    let highlighted: Bool
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .background(Color.accentColor.opacity(highlighted ? 0.18 : 0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Similarity actions shared by library, Playing, and playlist menus.
struct SimilarityActions: View {
    @Bindable var model: AppModel
    let tracks: () -> [TrackRecord]

    var body: some View {
        Button { model.similarity.startMix(tracks()) } label: { Label("Start Similar Mix", systemImage: "sparkles") }
        Button { model.similarity.request = SimilarityRequest(seed: tracks(), dynamic: false) } label: {
            Label("Create Similar Playlist…", systemImage: "list.bullet.rectangle")
        }
    }
}

struct SimilarPlaylistSheet: View {
    @Bindable var model: AppModel
    @Bindable var similarity: SimilarityController
    let request: SimilarityRequest
    @State private var dynamic: Bool
    @State private var limitsLength = false
    @State private var limit = 50
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, request: SimilarityRequest) {
        self.model = model; self.similarity = model.similarity; self.request = request
        _dynamic = State(initialValue: request.dynamic)
    }

    var body: some View {
        let (title, subtitle) = SimilarityController.describe(request.seed)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ArtworkView(track: request.seed.first, model: model).frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Similar to").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            Picker("Type", selection: $dynamic) {
                Text("Fixed Playlist").tag(false); Text("Dynamic Mix").tag(true)
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            Form {
                if dynamic {
                    Picker("Follow", selection: $model.settings.similarMixFollow) {
                        ForEach(SimilarMixFollow.allCases) { Text($0.longTitle).tag($0) }
                    }
                    Text("Only the next track is announced. Skipped tracks never come back during the mix.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle("Limit length", isOn: $limitsLength)
                    LabeledContent("Maximum tracks") {
                        HStack {
                            TextField("Maximum tracks", value: $limit, format: .number).labelsHidden()
                                .frame(width: 50).multilineTextAlignment(.trailing)
                            Stepper("Maximum tracks", value: $limit, in: 1...1000).labelsHidden()
                        }
                    }.disabled(!limitsLength)
                }
                LabeledContent("Similarity from") {
                    VStack(alignment: .trailing, spacing: 3) {
                        if similarity.lastFMAvailable {
                            Label("Last.fm", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label("Last.fm: add an API key in Settings › Services", systemImage: "minus.circle").foregroundStyle(.secondary)
                        }
                        Label("ListenBrainz", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }.font(.system(size: 11))
                }
                LabeledContent("Library") { Text("All sources").foregroundStyle(.secondary) }
            }.formStyle(.grouped).scrollDisabled(true).padding(.horizontal, -20)
            if let error = similarity.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            Spacer(minLength: 0)
            HStack {
                Label("Replaces the active playlist. Undo restores it.", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if similarity.isGenerating { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(dynamic ? "Start Mix" : "Generate") {
                    if dynamic { similarity.startMix(request.seed); dismiss() }
                    else { similarity.generatePlaylist(request.seed, limit: limitsLength ? max(1, limit) : nil) }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(similarity.isGenerating)
            }
        }
        .padding(20).frame(width: 460, height: 470)
        .onAppear { similarity.error = nil }
    }
}
