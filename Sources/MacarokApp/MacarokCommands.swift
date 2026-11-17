import AppKit
import KeyboardShortcuts
import MacarokCore
import SwiftUI
import UniformTypeIdentifiers

struct MacarokCommands: Commands {
    @Bindable var model: AppModel
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(model.queueUndoPresentation.undoTitle) { model.queueUndoPresentation.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.queueUndoPresentation.canUndo)
            Button(model.queueUndoPresentation.redoTitle) { model.queueUndoPresentation.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.queueUndoPresentation.canRedo)
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Music Folder…", action: model.pickFolder).keyboardShortcut("o")
            Button("Connect a Source…") { model.presentAddSource(from: .mainWindow) }.keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Import Playlist…") { choosePlaylist() }
            Button("Save Active Playlist…", action: model.savePlaylist).keyboardShortcut("s")
            Button("Export Active Playlist…", action: model.exportPlaylist).disabled(model.queue.isEmpty)
        }
        CommandMenu("Playback") {
            Button("Play / Pause", action: model.togglePlayback).keyboardShortcut(model.menuShortcut("playPause"))
            Button("Previous Track", action: model.previous).keyboardShortcut(model.menuShortcut("previousTrack"))
            Button("Next Track") { model.advance() }.keyboardShortcut(model.menuShortcut("nextTrack"))
            // ⌥← / ⌥→ are handled by the arrow monitor, so text fields keep moving by word.
            Button("Previous Chapter") { model.seekChapter(forward: false) }.disabled(!model.canSeekChapters)
            Button("Next Chapter") { model.seekChapter(forward: true) }.disabled(!model.canSeekChapters)
            Divider()
            Button("Shuffle Selected Library") { model.shuffle(model.displayedTracks) }.disabled(model.tracks.isEmpty)
            Picker("Repeat", selection: $model.settings.repeatMode) {
                Text("None").tag(RepeatMode.none)
                Text("Playlist").tag(RepeatMode.playlist)
                Text("Track").tag(RepeatMode.track)
            }
            Divider()
            Button("Clear Active Playlist", action: model.clearQueue).disabled(model.queue.isEmpty)
        }
        CommandMenu("Library") {
            Button("Search Library") { NotificationCenter.default.post(name: .macarokFocusSearch, object: nil) }.keyboardShortcut(model.menuShortcut("search"))
            Button("Show Current Track", action: model.showCurrentTrack).keyboardShortcut(model.menuShortcut("showCurrentTrack"))
            Button(model.isStoppingRefresh ? "Stopping Refresh…" : model.isRefreshing ? "Stop Refresh" : model.isAllSources ? "Refresh All Sources" : "Refresh Source", action: model.toggleRefresh)
                .keyboardShortcut("r").disabled(model.sources.isEmpty || model.isStoppingRefresh)
            ServerScanMenuItems(model: model)
            Divider()
            Button("Home") { model.selectLibraryView(.home) }.keyboardShortcut("1")
            Button("Artists") { model.selectLibraryView(.artists) }.keyboardShortcut("2")
            Button("Albums") { model.selectLibraryView(.albums) }.keyboardShortcut("3")
            Button("Years") { model.selectLibraryView(.years) }.keyboardShortcut("4")
            Button("Folders") { model.selectLibraryView(.folders) }.keyboardShortcut("5")
            Button("Tags") { model.selectLibraryView(.tags) }.keyboardShortcut("6")
            Divider()
            Menu("Saved Playlists") {
                if model.playlists.isEmpty { Text("No saved playlists") }
                ForEach(model.playlists) { playlist in Button(playlist.name) { model.loadSavedPlaylist(playlist) } }
            }
        }
        CommandMenu("Track") {
            Button("Add to Active Playlist") { if let track = model.selectedTrack { model.add([track]) } }.keyboardShortcut(model.menuShortcut("addToPlaylist")).disabled(model.selectedTrack == nil)
            Button("Edit Song Metadata…") { model.beginMetadataEditing(model.selectedTrack) }.keyboardShortcut("i").disabled(model.selectedTrack == nil || model.isRadioTrack(model.selectedTrack) || model.isPodcastTrack(model.selectedTrack))
            Button("Edit Album Metadata…") { model.beginAlbumMetadataEditing(model.selectedTrack) }.disabled(model.selectedTrack == nil || model.isRadioTrack(model.selectedTrack) || model.isPodcastTrack(model.selectedTrack))
            Button("Choose Artwork…") { model.beginArtworkEditing(model.selectedTrack) }.keyboardShortcut("i", modifiers: [.command, .shift]).disabled(model.selectedTrack == nil)
        }
        CommandGroup(replacing: .help) {
            Button("Playback Diagnostics…") { model.playbackDiagnostics.showWindow(appearance: model.settings.appearance.colorScheme) }
        }
    }

    private func choosePlaylist() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["m3u", "m3u8", "pls"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Import Playlist"
        if panel.runModal() == .OK, let url = panel.url { model.importPlaylist(url) }
    }
}

extension AppModel {
    func localShortcut(_ name: String) -> KeyboardShortcuts.Shortcut? {
        if let data = settings.localShortcuts[name] { return (try? JSONDecoder().decode(KeyboardShortcuts.Shortcut?.self, from: data)) ?? nil }
        switch name {
        case "playPause": return .init(.space)
        case "previousTrack": return .init(.leftArrow, modifiers: .command)
        case "nextTrack": return .init(.rightArrow, modifiers: .command)
        case "addToPlaylist": return .init(.return, modifiers: .command)
        case "search": return .init(.f, modifiers: .command)
        case "showCurrentTrack": return .init(.l, modifiers: .command)
        default: return nil
        }
    }

    func menuShortcut(_ name: String) -> KeyboardShortcut? {
        guard let shortcut = localShortcut(name), !shortcut.modifiers.isEmpty else { return nil }
        return shortcut.toSwiftUI
    }

    func performLocalShortcut(_ name: String) {
        switch name {
        case "playPause": togglePlayback()
        case "previousTrack": previous()
        case "nextTrack": advance()
        case "addToPlaylist": if let track = selectedTrack { add([track]) }
        case "search": NotificationCenter.default.post(name: .macarokFocusSearch, object: nil)
        case "showCurrentTrack": showCurrentTrack()
        default: break
        }
    }
}
