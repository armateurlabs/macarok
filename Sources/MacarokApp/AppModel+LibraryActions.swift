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
                guard self.store != nil else { return }
                let entries = try await Task.detached(priority: .userInitiated) { try PlaylistIO.read(url: url) }.value
                guard !entries.isEmpty else {
                    self.fail("Empty playlist", "No playable entries were found in this playlist.")
                    return
                }
                self.status = "Resolving playlist entries…"
                let resolution = try await self.performLibraryWork { store in
                    let existing = try store.allTracks()
                    var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    let sources = try store.sources()
                    let kinds = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.kind) })
                    var stations = try store.radioStations()
                    var importedRadio = false
                    var matches: [Int: [TrackRecord]] = [:]
                    var needsLocalIndex = false
                    for (index, entry) in entries.enumerated() {
                        if entry.isLiveRadio {
                            guard (try? RadioError.validatedURL(entry.url.absoluteString)) != nil else { continue }
                            if let id = entry.trackID, let station = stations.first(where: { $0.id == id }),
                               entry.sourceID == nil || station.sourceID == entry.sourceID {
                                matches[index] = [station.track]; continue
                            }
                            if let station = stations.first(where: { $0.streamURL == entry.url.absoluteString }) {
                                matches[index] = [station.track]; continue
                            }
                            let sourceID = entry.sourceID.flatMap { kinds[$0] == .radio ? $0 : nil } ?? RadioLibrary.sourceID
                            let preservedID = entry.trackID.flatMap { byID[$0] == nil ? $0 : nil }
                            var station = RadioStationRecord(id: preservedID, sourceID: sourceID,
                                                             name: entry.title?.isEmpty == false ? entry.title! : entry.url.host ?? "Radio Station",
                                                             streamURL: entry.url.absoluteString)
                            if byID[station.id] != nil { station.id = UUID().uuidString }
                            try store.saveRadioStation(station, favorite: false)
                            stations.append(station); byID[station.id] = station.track; importedRadio = true
                            matches[index] = [station.track]
                            continue
                        }
                        if let id = entry.trackID, let track = byID[id], entry.sourceID == nil || track.sourceID == entry.sourceID {
                            matches[index] = [track]
                            continue
                        }
                        let known = Self.matchingTracks(for: entry, in: existing)
                        if !known.isEmpty { matches[index] = known }
                        else if entry.url.isFileURL { needsLocalIndex = true }
                    }
                    return (matches: matches, needsLocalIndex: needsLocalIndex, importedRadio: importedRadio, sources: try store.sources())
                }
                var matches = resolution.matches
                if resolution.importedRadio {
                    self.sources = resolution.sources
                    if self.libraryScope == nil { self.selectAddedSource(RadioLibrary.sourceID) }
                    await self.radio?.reload()
                    self.reloadLibrary()
                }

                if resolution.needsLocalIndex {
                    let source = try await self.explicitLocalSource(url: url, preferredName: url.deletingPathExtension().lastPathComponent)
                    self.status = "Reading playlist files…"
                    let result = try await LibraryScanner().scan(source: source, metadataReader: { try TagLibMetadataService.read(url: $0) })
                    let existingMatches = matches
                    let imported = try await self.performLibraryWork { store in
                        if result.isComplete { try store.replaceSourceTracks(sourceID: source.id, with: result.tracks) }
                        else { try store.upsertTracks(result.tracks) }
                        var matches = existingMatches
                        for (index, entry) in entries.enumerated() where matches[index] == nil {
                            let found = Self.matchingTracks(for: entry, in: result.tracks)
                            if !found.isEmpty { matches[index] = found }
                        }
                        return (matches: matches, sources: try store.sources())
                    }
                    self.scanWarnings = result.warnings
                    matches = imported.matches
                    self.sources = imported.sources
                    self.selectAddedSource(source.id)
                    self.reloadLibrary()
                }

                let finalMatches = matches
                let result = await Task.detached(priority: .userInitiated) {
                    (values: entries.indices.flatMap { finalMatches[$0] ?? [] }, missing: entries.indices.filter { finalMatches[$0] == nil }.count)
                }.value
                let values = result.values
                let missing = result.missing
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
                guard self.store != nil else { return }
                let entry = PlaylistEntry(url: url)
                let known = try await self.performLibraryWork { store in
                    Self.matchingTracks(for: entry, in: try store.allTracks())
                }
                if !known.isEmpty { self.add(known); self.inspect(known[0]); return }

                let source = try await self.explicitLocalSource(url: url, preferredName: url.deletingPathExtension().lastPathComponent)
                self.status = "Reading “\(url.lastPathComponent)”…"
                let result = try await LibraryScanner().scan(source: source, metadataReader: { try TagLibMetadataService.read(url: $0) })
                self.sources = try await self.performLibraryWork { store in
                    if result.isComplete { try store.replaceSourceTracks(sourceID: source.id, with: result.tracks) }
                    else { try store.upsertTracks(result.tracks) }
                    return try store.sources()
                }
                self.selectAddedSource(source.id)
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
        Task { [weak self] in
            guard let self else { return }
            do {
                let values = try await self.performLibraryWork { try $0.playlistTracks(id: playlist.id) }
                guard !values.isEmpty else {
                    self.fail("Empty playlist", "This saved playlist has no available entries.")
                    return
                }
                self.add(values)
            } catch { self.fail("Could not load the playlist", error.localizedDescription) }
        }
    }

    /// Paths are relative to a source, never manufactured from tags.
    func folderPath(_ track: TrackRecord) -> String {
        let matchingSources = track.remotePath?.isEmpty == false ? [] : sources.filter { $0.id == track.sourceID }
        return LibraryFolderPathResolver(sources: matchingSources).folderPath(track)
    }

    func tracksInFolder(_ path: String) -> [TrackRecord] {
        cachedTracksInFolder(isAllSources ? path : LibraryFolderPathResolver.normalize(path))
    }

    var folderTracks: [TrackRecord] { tracksInFolder(selectedFolder ?? "") }

    private func explicitLocalSource(url: URL, preferredName: String) async throws -> SourceRecord {
        if let existing = sources.first(where: { $0.kind == .local && $0.url?.standardizedFileURL == url.standardizedFileURL }) { return existing }
        let bookmark = await Task.detached(priority: .userInitiated) {
            try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }.value
        let source = SourceRecord(kind: .local, name: preferredName.isEmpty ? url.lastPathComponent : preferredName,
                                  location: url.absoluteString, bookmarkData: bookmark)
        return try await performLibraryWork { store in
            if let existing = try store.sources().first(where: { $0.kind == .local && $0.url?.standardizedFileURL == url.standardizedFileURL }) { return existing }
            try store.saveSource(source)
            return source
        }
    }

    nonisolated private static func matchingTracks(for entry: PlaylistEntry, in candidates: [TrackRecord]) -> [TrackRecord] {
        let candidates = entry.sourceID.map { origin in candidates.filter { $0.sourceID == origin } } ?? candidates
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

    func currentPlaylistEntries() -> [PlaylistEntry] {
        let radioIDs = Set(sources.filter { $0.kind == .radio }.map(\.id))
        return queue.map { PlaylistEntry(track: $0.track, isLiveRadio: radioIDs.contains($0.track.sourceID)) }
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
        let tracks = queue.map(\.track)
        let entries = currentPlaylistEntries()
        Task { [weak self] in
            guard let self else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try PlaylistIO.write(entries: entries, to: url)
                }.value
                if saveInLibrary {
                    self.playlists = try await self.performLibraryWork { store in
                        try store.savePlaylist(name: url.deletingPathExtension().lastPathComponent, trackIDs: tracks.map(\.id))
                        return try store.playlists()
                    }
                }
                self.status = "Saved “\(url.lastPathComponent)”."
            } catch { self.fail("Could not save the playlist", error.localizedDescription) }
        }
    }

}
