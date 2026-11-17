import AppKit
import MacarokAudio
import MacarokCore
import Observation
import SwiftUI

/// The host retains this lightweight presentation, never AppModel. Actions resolve a weak controller.
@MainActor @Observable
final class MenuBarPlayerPresentation {
    enum Action: CaseIterable { case playPause, previous, next, previousChapter, nextChapter, showWindow, quit }
    struct State: Equatable {
        var enabled = false
        var track: TrackRecord? = nil
        var artist = ""
        var phase: PlaybackState = .stopped
        var active = false
        var canPlay = false
        var hasQueue = false
        var isRadio = false
        var reconnect = false
        var appearance: Appearance = .system
        var artworkRevision = 0
        /// Chapters of the playing podcast episode; empty otherwise.
        var chapters: [PodcastChapter] = []
        var canSeekChapters = false
        static let disabled = State()
        var hasChapters: Bool { chapters.count > 1 }
        var title: String { track?.title ?? "Nothing playing" }
        var playPauseTitle: String { active ? "Pause" : reconnect ? "Reconnect" : "Play" }
        var playPauseSymbol: String { active ? "pause.fill" : reconnect ? "arrow.clockwise" : "play.fill" }
        var artworkKey: String { "\(track?.sourceID ?? ""): \(track?.id ?? ""): \(track?.artworkPath ?? ""): \(artworkRevision)" }
        var status: String {
            if reconnect { return "Disconnected" }
            if active && phase == .stopped { return "Opening…" }
            switch phase {
            case .opening: return "Opening…"
            case .buffering: return "Buffering…"
            case .playing: return "Playing"
            case .paused: return "Paused"
            case .failed: return "Playback unavailable"
            case .stopped: return track == nil ? "Nothing playing" : "Stopped"
            }
        }
    }
    var state: State = .disabled
    let timeline: PlaybackTimeline
    @ObservationIgnored var action: ((Action) -> Void)?
    @ObservationIgnored var prepareArtwork: (() async -> Void)?
    init(timeline: PlaybackTimeline) { self.timeline = timeline }
    func perform(_ action: Action) {
        guard state.enabled else { return }
        switch action {
        case .playPause: guard state.canPlay else { return }
        case .previous, .next: guard state.hasQueue else { return }
        case .previousChapter, .nextChapter: guard state.hasChapters, state.canSeekChapters else { return }
        case .showWindow, .quit: break
        }
        self.action?(action)
    }
}

struct MenuBarMiniPlayerView: View {
    @Bindable var player: MenuBarPlayerPresentation
    var dismiss: () -> Void = { }

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 13) {
                MenuBarArtwork(player: player).frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.state.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        .frame(height: 35, alignment: .topLeading).accessibilityIdentifier("menuBarTrackTitle")
                    Text(player.state.artist.isEmpty ? "Macarok" : player.state.artist).font(.system(size: 12))
                        .foregroundStyle(.secondary).lineLimit(2).frame(height: 30, alignment: .topLeading)
                        .accessibilityIdentifier("menuBarTrackArtist")
                    if player.state.isRadio {
                        Label("LIVE", systemImage: "dot.radiowaves.left.and.right").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary).accessibilityIdentifier("menuBarLiveLabel")
                    } else if player.state.hasChapters {
                        MenuBarChapterLabel(timeline: player.timeline, chapters: player.state.chapters)
                    } else {
                        Text(player.state.track?.album ?? "").font(.system(size: 10)).foregroundStyle(.tertiary)
                            .lineLimit(1).accessibilityIdentifier("menuBarTrackAlbum")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 96)
            MenuBarPlaybackProgress(timeline: player.timeline, state: player.state)
                .frame(height: 32)
            HStack(spacing: player.state.hasChapters ? 12 : 25) {
                if player.state.hasChapters { chapterButton(forward: false) }
                transport("Previous", symbol: "backward.end.fill", action: .previous, enabled: player.state.hasQueue)
                Button { player.perform(.playPause) } label: {
                    Image(systemName: player.state.playPauseSymbol).font(.system(size: 19, weight: .semibold))
                        .frame(width: 48, height: 48).contentShape(Circle())
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain).disabled(!player.state.canPlay)
                .help(player.state.playPauseTitle).accessibilityLabel(player.state.playPauseTitle)
                .accessibilityIdentifier("menuBarPlayPause")
                transport("Next", symbol: "forward.end.fill", action: .next, enabled: player.state.hasQueue)
                if player.state.hasChapters { chapterButton(forward: true) }
            }.frame(maxWidth: .infinity).frame(height: 48)
            Divider()
            HStack {
                Button { dismiss(); player.perform(.showWindow) } label: { Label("Show Macarok", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.borderless).accessibilityIdentifier("menuBarShowWindow")
                Spacer()
                Menu {
                    Button("Quit Macarok") { dismiss(); player.perform(.quit) }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 14)) }
                    .menuStyle(.borderlessButton).fixedSize().help("More")
                    .accessibilityLabel("More").accessibilityIdentifier("menuBarMore")
            }.font(.system(size: 11)).frame(height: 22)
        }
        .padding(16).frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(player.state.appearance.colorScheme)
        .accessibilityIdentifier("menuBarMiniPlayer")
    }

    private func chapterButton(forward: Bool) -> some View {
        let label = forward ? "Next chapter" : "Previous chapter"
        return Button { player.perform(forward ? .nextChapter : .previousChapter) } label: {
            Image(systemName: forward ? "arrow.right.to.line" : "arrow.left.to.line").font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 38).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(!player.state.canSeekChapters)
            .help(label).accessibilityLabel(label)
            .accessibilityIdentifier(forward ? "menuBarNextChapter" : "menuBarPreviousChapter")
    }

    private func transport(_ label: String, symbol: String, action: MenuBarPlayerPresentation.Action, enabled: Bool) -> some View {
        Button { player.perform(action) } label: {
            Image(systemName: symbol).font(.system(size: 17)).frame(width: 38, height: 38).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled).help(label).accessibilityLabel(label)
            .accessibilityIdentifier(action == .previous ? "menuBarPrevious" : "menuBarNext")
    }
}

/// ImageIO and file access stay in the shared bounded thumbnail cache, outside the foreground.
private struct MenuBarArtwork: View {
    @Bindable var player: MenuBarPlayerPresentation
    @State private var image: NSImage?
    @State private var loadedKey: String?
    private var key: String { player.state.artworkKey }
    var body: some View {
        RoundedRectangle(cornerRadius: 7).fill(.quaternary)
            .overlay {
                if loadedKey == key, let image {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 96, height: 96).clipped()
                } else {
                    Image(systemName: player.state.isRadio ? "antenna.radiowaves.left.and.right" : "opticaldisc")
                        .resizable().scaledToFit().foregroundStyle(.tertiary).padding(21)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .task(id: key) {
                image = nil; loadedKey = nil
                guard player.state.enabled else { return }
                if player.state.track?.artworkPath == nil { await player.prepareArtwork?() }
                guard !Task.isCancelled, let path = player.state.track?.artworkPath else { return }
                let expectedKey = key
                let thumbnail = await ArtworkThumbnailCache.shared.image(at: path, revision: player.state.artworkRevision, pixelSize: 256)
                guard !Task.isCancelled, key == expectedKey else { return }
                image = thumbnail.map { NSImage(cgImage: $0.cgImage, size: .zero) }; loadedKey = expectedKey
            }
            .accessibilityLabel(player.state.isRadio ? "Station artwork" : "Album artwork")
            .accessibilityIdentifier("menuBarArtwork")
    }
}

/// The chapter being heard; only this label follows the clock.
private struct MenuBarChapterLabel: View {
    @ObservedObject var timeline: PlaybackTimeline
    let chapters: [PodcastChapter]
    var body: some View {
        let index = PodcastController.chapterIndex(chapters, at: timeline.position) ?? 0
        let title = chapters[index].title.isEmpty ? "Chapter \(index + 1)" : chapters[index].title
        Text("\(index + 1)/\(chapters.count) · \(title)").font(.system(size: 10)).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
            .accessibilityLabel("Chapter \(index + 1) of \(chapters.count): \(title)").accessibilityIdentifier("menuBarChapter")
    }
}

/// Clock publications redraw only this visible progress row, not the status item or artwork.
private struct MenuBarPlaybackProgress: View {
    @ObservedObject var timeline: PlaybackTimeline
    let state: MenuBarPlayerPresentation.State
    var body: some View {
        VStack(spacing: 5) {
            if !state.isRadio, state.track != nil, timeline.duration > 0 {
                ProgressView(value: min(1, max(0, timeline.position / timeline.duration)))
                    .progressViewStyle(.linear).accessibilityLabel("Playback progress")
                HStack {
                    Text(timeline.position.playbackTime)
                    Spacer()
                    Text(timeline.duration.playbackTime)
                }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text(state.status).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.accessibilityIdentifier("menuBarPlaybackProgress")
    }
}

#Preview("Menu Bar Mini Player — Light") {
    let player = MenuBarPlayerPresentation(timeline: VLCPlaybackEngine().timeline)
    player.state = .init(enabled: true, track: TrackRecord(id: "preview", sourceID: "preview", title: "A Window Into the World", artist: "The Midnight", album: "Endless Summer"), artist: "The Midnight", phase: .paused, canPlay: true, hasQueue: true, appearance: .light)
    return MenuBarMiniPlayerView(player: player)
}

#Preview("Menu Bar Mini Player — Dark Radio") {
    let player = MenuBarPlayerPresentation(timeline: VLCPlaybackEngine().timeline)
    player.state = .init(enabled: true, track: TrackRecord(id: "radio", sourceID: "radio", title: "Night Radio", artist: "Internet Radio"), artist: "Artist — Current broadcast", phase: .stopped, canPlay: true, hasQueue: true, isRadio: true, reconnect: true, appearance: .dark)
    return MenuBarMiniPlayerView(player: player)
}
