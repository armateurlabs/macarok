import AppKit
import Foundation
import MacarokCore
import MacarokMetadata
import UniformTypeIdentifiers

extension AppModel {
    /// Opening a playlist appends its entries; the current item keeps playing.
    func importPlaylist(_ url: URL) {
        Task { [weak self] in
            guard let self else { return }
            await self.start()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = self.store else { return }
                let entries = try await Task.detached(priority: .userInitiated) { try PlaylistIO.read(url: url) }.value
                guard !entries.isEmpty else {
                    self.fail("Empty playlist", "No playable entries were found in this playlist.")
                    return
                }
                let existing = try store.allTracks()
                var matches: [Int: [TrackRecord]] = [:]
                var needsLocalIndex = false
                for (index, entry) in entries.enumerated() {
                    if let id = entry.trackID, let track = existing.first(where: { $0.id == id && (entry.sourceID == nil || $0.sourceID == entry.sourceID) }) {
                        matches[index] = [track]
                        continue
                    }
                    let known = self.matchingTracks(for: entry, in: existing)
                    if !known.isEmpty { matches[index] = known }
                    else if entry.url.isFileURL { needsLocalIndex = true }
                }

                if needsLocalIndex {
                    let source = try self.explicitLocalSource(url: url, preferredName: url.deletingPathExtension().lastPathComponent)
                    self.status = "Reading playlist files…"
                    let result = try await LibraryScanner().scan(source: source, metadataReader: { try TagLibMetadataService.read(url: $0) })
                    if result.isComplete { try store.replaceSourceTracks(sourceID: source.id, with: result.tracks) }
                    else { try store.upsertTracks(result.tracks) }
                    self.scanWarnings = result.warnings
                    for (index, entry) in entries.enumerated() where matches[index] == nil {
                        let found = self.matchingTracks(for: entry, in: result.tracks)
                        if !found.isEmpty { matches[index] = found }
                    }
                    self.sources = try store.sources()
                    self.sourceID = source.id
                    self.reloadLibrary()
                }

                let values = entries.indices.flatMap { matches[$0] ?? [] }
                let missing = entries.indices.filter { matches[$0] == nil }.count
                if !values.isEmpty {
                    self.add(values)
                    if let first = values.first { self.inspect(first) }
                    if missing > 0 {
                        self.status = "Added \(values.count) tracks; \(missing) playlist entries are unavailable or need their original source."
                    }
                } else {
                    self.fail("Playlist sources unavailable", "Reconnect the original sources or choose a playlist whose local files are available. Remote Macarok entries retain their original source references.")
                }
            } catch {
                self.fail("Could not import the playlist", error.localizedDescription)
            }
        }
    }

    /// Explicit file sources index just the opened file or the audio referenced by its CUE sheet.
    func importAudioFile(_ url: URL) {
        Task { [weak self] in
            guard let self else { return }
            await self.start()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = self.store else { return }
                let entry = PlaylistEntry(url: url)
                let known = self.matchingTracks(for: entry, in: try store.allTracks())
                if !known.isEmpty { self.add(known); self.inspect(known[0]); return }

                let source = try self.explicitLocalSource(url: url, preferredName: url.deletingPathExtension().lastPathComponent)
                self.status = "Reading “\(url.lastPathComponent)”…"
                let result = try await LibraryScanner().scan(source: source, metadataReader: { try TagLibMetadataService.read(url: $0) })
                if result.isComplete { try store.replaceSourceTracks(sourceID: source.id, with: result.tracks) }
                else { try store.upsertTracks(result.tracks) }
                self.sources = try store.sources()
                self.sourceID = source.id
                self.reloadLibrary()
                self.scanWarnings = result.warnings
                guard !result.tracks.isEmpty else {
                    self.fail("No audio tracks found", "The selected file did not contain a readable audio track.")
                    return
                }
                self.add(result.tracks)
                self.inspect(result.tracks[0])
            } catch {
                self.fail("Could not import the audio file", error.localizedDescription)
            }
        }
    }

    func savePlaylist() { writeCurrentPlaylist(saveInLibrary: true) }
    func exportPlaylist() { writeCurrentPlaylist(saveInLibrary: false) }

    func loadSavedPlaylist(_ playlist: PlaylistRecord) {
        do {
            let values = try store?.playlistTracks(id: playlist.id) ?? []
            guard !values.isEmpty else {
                fail("Empty playlist", "This saved playlist has no available entries.")
                return
            }
            add(values)
        } catch { fail("Could not load the playlist", error.localizedDescription) }
    }

    /// Paths are relative to a source, never manufactured from tags.
    func folderPath(_ track: TrackRecord) -> String {
        let matchingSources = track.remotePath?.isEmpty == false ? [] : sources.filter { $0.id == track.sourceID }
        return LibraryFolderPathResolver(sources: matchingSources).folderPath(track)
    }

    func tracksInFolder(_ path: String) -> [TrackRecord] {
        let folder = LibraryFolderPathResolver.normalize(path)
        guard !folder.isEmpty else { return displayedTracks }
        let resolver = LibraryFolderPathResolver(sources: selectedSource.map { [$0] } ?? [])
        return displayedTracks.filter { track in
            let parent = resolver.folderPath(track)
            return parent == folder || parent.hasPrefix(folder + "/")
        }
    }

    var folderTracks: [TrackRecord] { tracksInFolder(selectedFolder ?? "") }

    private func explicitLocalSource(url: URL, preferredName: String) throws -> SourceRecord {
        if let existing = sources.first(where: { $0.kind == .local && $0.url?.standardizedFileURL == url.standardizedFileURL }) { return existing }
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let source = SourceRecord(kind: .local, name: preferredName.isEmpty ? url.lastPathComponent : preferredName,
                                  location: url.absoluteString, bookmarkData: bookmark)
        try store?.saveSource(source)
        return source
    }

    private func matchingTracks(for entry: PlaylistEntry, in candidates: [TrackRecord]) -> [TrackRecord] {
        if entry.url.isFileURL, entry.url.pathExtension.lowercased() == "cue" {
            let matching = candidates.filter { $0.cuePath == entry.url.standardizedFileURL.path }
            let sourceID = matching.first?.sourceID
            return matching.filter { $0.sourceID == sourceID }.sorted(by: TrackRecord.libraryOrder)
        }
        let matching = candidates.filter { track in
            guard let url = track.url else { return false }
            return entry.url.isFileURL && url.isFileURL
                ? url.standardizedFileURL.path == entry.url.standardizedFileURL.path
                : url.absoluteString == entry.url.absoluteString
        }
        if entry.startTime != nil || entry.endTime != nil {
            return matching.filter { track in
                let sameStart = abs((track.startTime ?? 0) - (entry.startTime ?? 0)) < 0.000_001
                let sameEnd: Bool
                if let expected = entry.endTime, let actual = track.endTime { sameEnd = abs(expected - actual) < 0.000_001 }
                else { sameEnd = entry.endTime == nil && track.endTime == nil }
                return sameStart && sameEnd
            }.prefix(1).map { $0 }
        }
        // One physical album file may intentionally resolve to several CUE tracks.
        let source = matching.first?.sourceID
        let inOneSource = matching.filter { $0.sourceID == source }
        if inOneSource.contains(where: \.isCUETrack) { return inOneSource.sorted(by: TrackRecord.libraryOrder) }
        return inOneSource.prefix(1).map { $0 }
    }

    private func writeCurrentPlaylist(saveInLibrary: Bool) {
        guard !queue.isEmpty else {
            fail("Empty playlist", "Add tracks to the active playlist before saving it.")
            return
        }
        let panel = NSSavePanel()
        panel.title = saveInLibrary ? "Save Playlist" : "Export Playlist"
        panel.nameFieldStringValue = "Playlist.m3u8"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = ["m3u8", "m3u", "pls"].compactMap { UTType(filenameExtension: $0) }
        panel.message = queue.contains(where: { $0.track.isCUETrack })
            ? "M3U preserves the playback boundaries of CUE tracks."
            : "Save the active playlist as M3U or PLS."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PlaylistIO.write(entries: queue.map { PlaylistEntry(track: $0.track) }, to: url)
            if saveInLibrary {
                try store?.savePlaylist(name: url.deletingPathExtension().lastPathComponent, trackIDs: queue.map(\.track.id))
                playlists = try store?.playlists() ?? []
            }
            status = "Saved “\(url.lastPathComponent)”."
        } catch { fail("Could not save the playlist", error.localizedDescription) }
    }

}
