import MacarokAudio
import MacarokCore
import SwiftUI

struct LyricsPane: View {
    @Bindable var model: AppModel
    @State private var controller: LyricsController
    @State private var autoScroll = true

    init(model: AppModel) {
        self.model = model
        _controller = State(initialValue: LyricsController(model: model))
    }

    private var targetTrack: TrackRecord? { model.lyricsContextTrack }

    var body: some View {
        VStack(spacing: 0) {
            if let track = controller.track {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.system(size: 19, weight: .semibold)).lineLimit(2)
                        HStack { Text(track.artist).foregroundStyle(.secondary).lineLimit(1); SourceBadge(model: model, sourceID: track.sourceID) }
                            .font(.system(size: 12))
                    }
                    HStack(spacing: 8) {
                        Button("Find Lyrics…", action: controller.openSearch).disabled(controller.isLiveRadio)
                        Button("Edit / Paste…", action: controller.openEditor).disabled(controller.isLiveRadio)
                        Button("Save to Files") { Task { await controller.saveToFiles() } }
                            .disabled(!controller.canSaveToFiles || controller.isSavingToFiles)
                        if controller.isSavingToFiles { ProgressView().controlSize(.mini) }
                        Spacer(minLength: 0)
                    }.controlSize(.small)
                    HStack(spacing: 8) {
                        if !controller.sourceLabel.isEmpty { Text(controller.sourceLabel).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer(minLength: 0)
                        if controller.hasSynchronizedLyrics {
                            Toggle("Auto-scroll", isOn: $autoScroll).toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
                                .fixedSize()
                        }
                    }
                    if let notice = controller.notice { Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                Divider()
            }
            lyricsContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: LyricsController.requestKey(for: targetTrack)) { await controller.load(track: targetTrack) }
        .onDisappear { controller.cancel() }
        .sheet(isPresented: $controller.showsSearch) { LyricsSearchSheet(controller: controller) }
        .sheet(isPresented: $controller.showsEditor) { LyricsEditorSheet(controller: controller) }
        .accessibilityIdentifier("lyricsPane")
    }

    @ViewBuilder private var lyricsContent: some View {
        switch controller.state {
        case .idle:
            ContentUnavailableView("Choose a Track", systemImage: "text.quote", description: Text("Play or select a track to see its lyrics."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            ProgressView("Loading lyrics…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if controller.hasSynchronizedLyrics { SynchronizedLyricsView(model: model, controller: controller, autoScroll: $autoScroll, timeline: model.player.timeline) }
            else {
                ScrollView {
                    Text(controller.plainText).font(.system(size: 14)).lineSpacing(7).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(22)
                }
            }
        case .notFound:
            ContentUnavailableView {
                Label("No Lyrics Found", systemImage: "text.quote")
            } description: {
                Text("Try a different artist or title, or paste your own lyrics.")
            } actions: {
                Button("Find Lyrics…", action: controller.openSearch)
                Button("Paste Lyrics…", action: controller.openEditor)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .instrumental:
            ContentUnavailableView("Instrumental", systemImage: "pianokeys", description: Text("This recording is marked as instrumental."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label(controller.errorTitle, systemImage: "exclamationmark.bubble")
            } description: {
                Text(controller.errorMessage ?? "Lyrics could not be loaded. Try again or search manually.")
            } actions: {
                if !controller.isLiveRadio {
                    Button("Try Again") { Task { await controller.reload() } }
                    Button("Find Lyrics…", action: controller.openSearch)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

}

private struct SynchronizedLyricsView: View {
    @Bindable var model: AppModel
    @Bindable var controller: LyricsController
    @Binding var autoScroll: Bool
    let timeline: PlaybackTimeline
    @State private var activeID: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(controller.displayLines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 14, weight: activeID == line.id ? .semibold : .regular))
                            .foregroundStyle(activeID == line.id ? Color.accentColor : Color.primary)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                            .id(line.id)
                    }
                }.padding(22)
            }
            .onChange(of: activeID) { _, id in scroll(to: id, with: proxy) }
            .onChange(of: autoScroll) { _, enabled in if enabled { scroll(to: activeID, with: proxy) } }
            .onAppear { scroll(to: activeID, with: proxy) }
        }
        .background {
            ActiveLyricsLineObserver(model: model, controller: controller, timeline: timeline, activeID: $activeID)
                .frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }

    private func scroll(to id: Int?, with proxy: ScrollViewProxy) {
        guard autoScroll, let id else { return }
        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
    }
}

/// Only this zero-size observer samples the clock; the lyric stack changes at line boundaries.
private struct ActiveLyricsLineObserver: View {
    let model: AppModel
    let controller: LyricsController
    @ObservedObject var timeline: PlaybackTimeline
    @Binding var activeID: Int?

    private var lineID: Int? {
        guard let track = controller.track, let current = model.currentTrack,
              current.id == track.id, current.sourceID == track.sourceID,
              controller.hasSynchronizedLyrics else { return nil }
        return controller.activeLineID(at: timeline.position)
    }

    var body: some View {
        Color.clear.onChange(of: lineID, initial: true) { _, next in
            if activeID != next { activeID = next }
        }
    }
}

private struct LyricsSearchSheet: View {
    @Bindable var controller: LyricsController
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var isApplying = false

    private var selectedResult: LyricsSearchItem? { controller.searchResults.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Find Lyrics").font(.title2.weight(.semibold))
            Text(controller.sheetTrackTitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow { Text("Title"); TextField("Title", text: $controller.searchTitle) }
                GridRow { Text("Artist"); TextField("Artist", text: $controller.searchArtist) }
                GridRow { Text("Album"); TextField("Album", text: $controller.searchAlbum) }
            }.textFieldStyle(.roundedBorder).onSubmit { search() }
            HStack {
                Text("Search LRCLIB for another match.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if controller.isSearching { ProgressView().controlSize(.small) }
                Button("Search", action: search).disabled(controller.isSearching || (controller.searchTitle.isEmpty && controller.searchArtist.isEmpty))
            }
            if let error = controller.searchError { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            List(selection: $selection) {
                ForEach(controller.searchResults) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(result.title).fontWeight(.medium).lineLimit(1); Spacer(); Text(result.duration.playbackTime).foregroundStyle(.secondary).monospacedDigit() }
                        Text([result.artist, result.album].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary).lineLimit(1)
                    }.font(.system(size: 12)).padding(.vertical, 4).tag(result.id)
                }
            }.overlay {
                if controller.searchResults.isEmpty && !controller.isSearching {
                    ContentUnavailableView("No Matches", systemImage: "magnifyingglass", description: Text("Try a shorter title or leave the album blank."))
                }
            }.frame(minHeight: 150)
            GroupBox("Preview") {
                ScrollView {
                    Text(selectedResult?.plainText ?? "Select a result to preview its lyrics.")
                        .font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.frame(height: 100)
            }
            HStack {
                Link("LRCLIB", destination: URL(string: "https://lrclib.net")!).font(.caption)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isApplying)
                Button("Use Lyrics") {
                    guard let selectedResult else { return }
                    isApplying = true
                    Task { await controller.useResult(selectedResult); isApplying = false }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(selectedResult == nil || isApplying)
            }
        }.padding(22).frame(width: 590, height: 590)
        .interactiveDismissDisabled(isApplying)
        .task { await controller.search() }
        .onChange(of: controller.searchResults.map(\.id)) { _, ids in if !ids.contains(selection ?? "") { selection = ids.first } }
    }

    private func search() { Task { await controller.search() } }
}

private struct LyricsEditorSheet: View {
    @Bindable var controller: LyricsController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Lyrics").font(.title2.weight(.semibold))
            Text(controller.sheetTrackTitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Text("Paste plain lyrics or timestamped LRC. Save keeps them in Macarok; Save to Files writes them to a local track.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $controller.editedText).font(.system(size: 13, design: .monospaced))
                .padding(5).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary)).disabled(controller.isSavingEdit)
            if let error = controller.editorError { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                if controller.isSavingEdit { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(controller.isSavingEdit)
                Button("Save") { Task { await controller.saveEditedLyrics() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(controller.isSavingEdit)
            }
        }.padding(22).frame(width: 590, height: 480).interactiveDismissDisabled(controller.isSavingEdit)
    }
}
