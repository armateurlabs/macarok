import Foundation
import MacarokCore
import MacarokMetadata

@MainActor
extension AppModel {
    func loadAlbumMetadata(session: AlbumMetadataEditingSession) async {
        guard !session.hasLoaded, !session.isLoading else { return }
        session.isLoading = true
        defer { session.isLoading = false }
        let target = session.track
        do {
            let tracks = try await performLibraryWork { try $0.albumTracks(sourceID: target.sourceID, albumID: target.albumID) }
            try Task.checkCancellation()
            session.tracks = tracks.sorted(by: TrackRecord.libraryOrder)
            session.hasLoaded = true
            if tracks.isEmpty { session.error = "This album is no longer available in its original source." }
        } catch is CancellationError { }
        catch { session.error = error.localizedDescription }
    }

    func applyAlbumMetadataEdits(session: AlbumMetadataEditingSession) async throws {
        let target = session.track
        guard session.draft.isValid, let source = sources.first(where: { $0.id == target.sourceID }), source.kind != .radio else {
            throw MetadataError.unsupported("The album's source is no longer available.")
        }
        let properties = session.properties
        let lockMetadata = session.protectValues || source.kind != .local
        let originals = try await performLibraryWork { try $0.albumTracks(sourceID: target.sourceID, albumID: target.albumID) }
        guard !originals.isEmpty else { throw MetadataError.unsupported("This album is no longer available in its original source.") }
        var writtenURLs: [URL] = []
        if source.kind == .local {
            _ = await accessFolder(source)
            writtenURLs = try await Task.detached(priority: .utility) {
                try AlbumMetadataFileWriter.write(properties: properties, tracks: originals)
            }.value
        }
        try Task.checkCancellation()
        guard sources.contains(where: { $0.id == target.sourceID }) else { throw MetadataError.unsupported("The album's source was removed while saving.") }
        let updates = try await performLibraryWork { store -> [String: TrackRecord] in
            var values: [String: TrackRecord] = [:]
            for original in originals {
                try Task.checkCancellation()
                guard let latest = try store.track(id: original.id), latest.sourceID == target.sourceID else { continue }
                // Re-read at commit so only the chosen shared fields supersede concurrent edits.
                var edited = AlbumMetadataDraft.applying(properties, to: latest)
                if source.kind == .local {
                    let cueFolder = latest.cuePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
                    edited.albumID = Self.metadataAlbumID(for: edited, source: source, cueFolder: cueFolder)
                }
                edited.metadataLocked = lockMetadata
                try store.updateTrackMetadata(edited)
                try store.setMetadataLocked(trackID: edited.id, locked: lockMetadata)
                if let saved = try store.track(id: edited.id) { values[saved.id] = saved }
            }
            return values
        }
        if !writtenURLs.isEmpty {
            let completedWrites = writtenURLs
            await Task.detached(priority: .utility) { LocalFileChangeSuppression.shared.recordWrites(urls: completedWrites) }.value
        }
        queueMetadataOverrides.merge(updates, uniquingKeysWith: { _, latest in latest })
        let updatedQueue = queue.map { item -> QueueItem in
            var value = item
            if let track = updates[item.track.id] { value.track = track }
            return value
        }
        if updatedQueue != queue { queue = updatedQueue }
        // Album/artist/year edits can change grouping; one rebuild covers the entire operation.
        reloadLibrary()
        status = source.kind == .local && !writtenURLs.isEmpty
            ? "Album metadata saved to \(writtenURLs.count) files."
            : "Album metadata saved as a local library correction."
    }
}

/// Album edits are grouped by physical destination, so virtual CUE tracks never rewrite one audio file repeatedly.
enum AlbumMetadataFileWriter {
    static func write(properties: [String: String], tracks: [TrackRecord]) throws -> [URL] {
        guard !properties.isEmpty else { return [] }
        var written: [URL] = []
        do {
            let cueGroups = Dictionary(grouping: tracks.filter { $0.cuePath != nil }, by: { URL(fileURLWithPath: $0.cuePath!).standardizedFileURL })
            for (url, values) in cueGroups.sorted(by: { $0.key.path < $1.key.path }) {
                try Task.checkCancellation()
                let artists = Dictionary(values.compactMap { track in track.trackNumber.map { ($0, track.artist) } }, uniquingKeysWith: { first, _ in first })
                try TagLibMetadataService.writeCUEAlbum(cueURL: url, properties: properties, fallbackTrackArtists: artists)
                written.append(url)
            }
            let files = Dictionary(grouping: tracks, by: { $0.url?.standardizedFileURL.resolvingSymlinksInPath() })
            for (possibleURL, values) in files.sorted(by: { ($0.key?.path ?? "") < ($1.key?.path ?? "") }) {
                try Task.checkCancellation()
                guard let url = possibleURL, url.isFileURL else { throw AppFailure.missingFile }
                let embedded = values.filter { $0.isCUETrack && $0.cuePath == nil }
                if !embedded.isEmpty {
                    let artists = Dictionary(embedded.compactMap { track in track.trackNumber.map { ($0, track.artist) } }, uniquingKeysWith: { first, _ in first })
                    let current = try TagLibMetadataService.properties(url: url)
                    if current["CUESHEET"]?.first != nil {
                        try TagLibMetadataService.writeEmbeddedCUEAlbum(audioURL: url, properties: properties, fallbackTrackArtists: artists)
                    } else {
                        var native = properties
                        if properties["ARTIST"] != nil || properties["ALBUMARTIST"] != nil {
                            for (number, artist) in artists { native[String(format: "MACAROK_CUE_TRACK_%02d_ARTIST", number)] = properties["ARTIST"] ?? artist }
                        }
                        try TagLibMetadataService.write(properties: native, to: url)
                    }
                } else { try TagLibMetadataService.write(properties: properties, to: url) }
                written.append(url)
            }
            return written
        } catch {
            if written.isEmpty || error is CancellationError { throw error }
            throw AlbumMetadataWriteFailure(writtenURLs: written, underlying: error)
        }
    }
}

private struct AlbumMetadataWriteFailure: LocalizedError {
    let writtenURLs: [URL]
    let underlying: Error
    var errorDescription: String? {
        "Could not save every album file. \(writtenURLs.count) \(writtenURLs.count == 1 ? "file already contains" : "files already contain") these changes. \(underlying.localizedDescription)"
    }
}
