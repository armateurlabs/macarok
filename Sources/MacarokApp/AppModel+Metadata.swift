import AppKit
import Foundation
import MacarokCore
import MacarokMetadata

enum MetadataServices {
    static let musicBrainz = MusicBrainzClient()
    static let acoustID = AcoustIDClient()
}

struct MetadataFieldChange: Identifiable {
    var key: String
    var label: String
    var before: String
    var after: String
    var id: String { key }
}

struct MetadataDraft: Equatable {
    var title: String
    var artist: String
    var albumArtist: String
    var album: String
    var year: String
    var genre: String
    var trackNumber: String
    var discNumber: String

    init(_ track: TrackRecord) {
        title = track.title; artist = track.artist; albumArtist = track.albumArtist; album = track.album
        year = track.year.map(String.init) ?? ""; genre = track.genre ?? ""
        trackNumber = track.trackNumber.map(String.init) ?? ""; discNumber = track.discNumber.map(String.init) ?? ""
    }

    func applying(to track: TrackRecord) -> TrackRecord {
        var result = track
        result.title = title; result.artist = artist; result.albumArtist = albumArtist; result.album = album
        result.year = Int(year); result.genre = genre.isEmpty ? nil : genre
        result.trackNumber = Int(trackNumber); result.discNumber = Int(discNumber)
        return result
    }

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (year.isEmpty || (Int(year).map { (1...9999).contains($0) } ?? false))
        && (trackNumber.isEmpty || (Int(trackNumber).map { $0 > 0 } ?? false))
        && (discNumber.isEmpty || (Int(discNumber).map { $0 > 0 } ?? false))
    }

    func changes(from track: TrackRecord) -> [MetadataFieldChange] {
        let old = MetadataDraft(track)
        return [
            ("TITLE", "Title", old.title, title), ("ARTIST", "Artist", old.artist, artist),
            ("ALBUMARTIST", "Album artist", old.albumArtist, albumArtist), ("ALBUM", "Album", old.album, album),
            ("DATE", "Year", old.year, year), ("GENRE", "Genre", old.genre, genre),
            ("TRACKNUMBER", "Track", old.trackNumber, trackNumber), ("DISCNUMBER", "Disc", old.discNumber, discNumber)
        ].compactMap { key, label, before, after in
            before == after ? nil : MetadataFieldChange(key: key, label: label, before: before, after: after)
        }
    }
}

@MainActor
extension AppModel {
    func applyMetadataEdits(original: TrackRecord, edited: TrackRecord, releaseID: String?, lockMetadata: Bool) async throws {
        guard store != nil, let source = sources.first(where: { $0.id == original.sourceID }) else {
            throw MetadataError.unsupported("The library source is no longer available.")
        }
        let changes = MetadataDraft(edited).changes(from: original)
        var properties = Dictionary(uniqueKeysWithValues: changes.map { ($0.key, $0.after) })
        if let releaseID { properties["MUSICBRAINZ_ALBUMID"] = releaseID }
        let cueSiblings: [TrackRecord]
        if original.isCUETrack {
            cueSiblings = try await performLibraryWork { store in
                try store.tracks(sourceID: original.sourceID, ordered: false).filter {
                    guard $0.id != original.id, $0.isCUETrack else { return false }
                    if let path = original.cuePath { return $0.cuePath == path }
                    return $0.fileURL == original.fileURL && $0.cuePath == nil
                }
            }
        } else { cueSiblings = [] }
        let cueTracks = [original] + cueSiblings
        let inheritedArtists = Dictionary(cueTracks.compactMap { value in
            value.trackNumber.map { ($0, value.artist) }
        }, uniquingKeysWith: { first, _ in first })
        let cueAudioURLs = Set(cueTracks.compactMap(\.url).filter(\.isFileURL))
        var cueAlbumFolder = original.cuePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        if source.kind == .local, let audioURL = original.url {
            _ = accessFolder(source)
            let fileEdits = properties
            let usesCUEAlbumFolder = try await Task.detached(priority: .userInitiated) { () throws -> Bool in
                if original.isCUETrack, let number = original.trackNumber {
                    let shared = fileEdits.filter { ["ALBUM", "ALBUMARTIST", "DATE", "GENRE", "MUSICBRAINZ_ALBUMID"].contains($0.key) }
                    if let cuePath = original.cuePath {
                        let cueURL = URL(fileURLWithPath: cuePath)
                        let text = try CUEParser.read(url: cueURL)
                        guard text.tracks.contains(where: { $0.number == number }) else { throw MetadataError.cueTrackNotFound(number) }
                        try TagLibMetadataService.writeCUETrack(cueURL: cueURL, trackNumber: number,
                            title: fileEdits["TITLE"], artist: fileEdits["ARTIST"], album: fileEdits["ALBUM"],
                            albumArtist: fileEdits["ALBUMARTIST"], genre: fileEdits["GENRE"], yearText: fileEdits["DATE"],
                            fallbackTrackArtists: inheritedArtists)
                        if !shared.isEmpty {
                            for url in cueAudioURLs { try TagLibMetadataService.write(properties: shared, to: url) }
                        }
                        return true
                    } else {
                        let current = try TagLibMetadataService.properties(url: audioURL)
                        if current["CUESHEET"]?.first != nil {
                            try TagLibMetadataService.writeEmbeddedCUETrack(audioURL: audioURL, trackNumber: number,
                                title: fileEdits["TITLE"], artist: fileEdits["ARTIST"], album: fileEdits["ALBUM"],
                                albumArtist: fileEdits["ALBUMARTIST"], genre: fileEdits["GENRE"], yearText: fileEdits["DATE"],
                                fallbackTrackArtists: inheritedArtists)
                            if !shared.isEmpty { try TagLibMetadataService.write(properties: shared, to: audioURL) }
                            return true
                        } else {
                            var native = shared
                            if fileEdits["ALBUMARTIST"] != nil {
                                for (number, artist) in inheritedArtists {
                                    native[String(format: "MACAROK_CUE_TRACK_%02d_ARTIST", number)] = artist
                                }
                            }
                            if let value = fileEdits["TITLE"] { native[String(format: "MACAROK_CUE_TRACK_%02d_TITLE", number)] = value }
                            if let value = fileEdits["ARTIST"] { native[String(format: "MACAROK_CUE_TRACK_%02d_ARTIST", number)] = value }
                            if !native.isEmpty { try TagLibMetadataService.write(properties: native, to: audioURL) }
                        }
                    }
                } else if !fileEdits.isEmpty {
                    try TagLibMetadataService.write(properties: fileEdits, to: audioURL)
                }
                return false
            }.value
            if usesCUEAlbumFolder && cueAlbumFolder == nil { cueAlbumFolder = audioURL.deletingLastPathComponent() }
        }
        let albumFolder = cueAlbumFolder
        let updates = try await performLibraryWork { store in
            var values = [edited]
            if original.isCUETrack && (edited.album != original.album || edited.albumArtist != original.albumArtist
                                      || edited.year != original.year || edited.genre != original.genre) {
                for var sibling in cueSiblings {
                    if edited.album != original.album { sibling.album = edited.album }
                    if edited.albumArtist != original.albumArtist { sibling.albumArtist = edited.albumArtist }
                    if edited.year != original.year { sibling.year = edited.year }
                    if edited.genre != original.genre { sibling.genre = edited.genre }
                    values.append(sibling)
                }
            }
            var updated: [String: TrackRecord] = [:]
            for var value in values {
                if source.kind == .local { value.albumID = Self.metadataAlbumID(for: value, source: source, cueFolder: albumFolder) }
                value.metadataLocked = lockMetadata || source.kind != .local
                try store.updateTrackMetadata(value)
                try store.setMetadataLocked(trackID: value.id, locked: value.metadataLocked)
                updated[value.id] = value
            }
            return updated
        }
        queueMetadataOverrides.merge(updates, uniquingKeysWith: { _, latest in latest })
        for index in queue.indices {
            if let value = updates[queue[index].track.id] { queue[index].track = value }
        }
        if let releaseID { UserDefaults.standard.set(releaseID, forKey: "Macarok.release.\(original.albumID)") }
        reloadLibrary()
        status = source.kind == .local ? "Metadata saved to the original files." : "Metadata saved as a local library correction."
    }

    func saveAlbumArtwork(data: Data, for track: TrackRecord, embedInFiles: Bool, saveSidecar: Bool) async throws {
        guard store != nil, let source = sources.first(where: { $0.id == track.sourceID }) else { throw AppFailure.invalidArtwork }
        let jpeg = try await Task.detached(priority: .userInitiated) { () throws -> Data? in
            guard let image = NSImage(data: data) else { throw AppFailure.invalidArtwork }
            guard saveSidecar else { return nil }
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
                throw AppFailure.invalidArtwork
            }
            return jpeg
        }.value
        let related = try await performLibraryWork { store in
            try store.tracks(sourceID: track.sourceID, ordered: false).filter { $0.albumID == track.albumID }
        }
        let targets = related.isEmpty ? [track] : related
        if source.kind == .local { _ = accessFolder(source) }
        if source.kind == .local && (embedInFiles || saveSidecar) {
            try await Task.detached(priority: .userInitiated) {
                let audioURLs = Array(Set(targets.compactMap(\.url))).filter(\.isFileURL)
                if embedInFiles {
                    for url in audioURLs { try TagLibMetadataService.write(properties: [:], artworkData: data, to: url) }
                }
                if saveSidecar {
                    guard let jpeg else { throw AppFailure.invalidArtwork }
                    for folder in Set(audioURLs.map { $0.deletingLastPathComponent() }) {
                        try jpeg.write(to: folder.appendingPathComponent("cover.jpg"), options: .atomic)
                    }
                }
            }.value
        }
        let cached = try await cacheArtwork(data, key: StableID.make(track.sourceID, track.albumID, "selected-artwork"))
        let updatedIDs = try await performLibraryWork { store in
            var ids: Set<String> = []
            for var target in targets {
                target.artworkPath = cached.path
                // Source refreshes cannot recreate a library-only artwork choice.
                target.metadataLocked = target.metadataLocked || !embedInFiles
                try store.updateTrackMetadata(target)
                try store.setMetadataLocked(trackID: target.id, locked: target.metadataLocked)
                ids.insert(target.id)
            }
            return ids
        }
        for index in queue.indices where updatedIDs.contains(queue[index].track.id) {
            queue[index].track.artworkPath = cached.path
        }
        for var target in targets where updatedIDs.contains(target.id) {
            target.artworkPath = cached.path
            target.metadataLocked = target.metadataLocked || !embedInFiles
            queueMetadataOverrides[target.id] = target
        }
        reloadLibrary(); artworkRevision += 1
        status = source.kind == .local && embedInFiles ? "Album artwork embedded in \(Set(targets.compactMap(\.fileURL)).count) audio files." : "Album artwork saved to the library."
    }

    func localArtwork(for track: TrackRecord) async -> [(name: String, detail: String, data: Data)] {
        if let source = sources.first(where: { $0.id == track.sourceID }), source.kind == .local { _ = accessFolder(source) }
        return await Task.detached(priority: .utility) {
            var results: [(String, String, Data)] = []
            if let url = track.url, url.isFileURL {
                if let metadata = try? TagLibMetadataService.read(url: url), let data = metadata.artworkData {
                    results.append(("Embedded", "Current front cover", data))
                }
                for name in ["cover.jpg", "folder.jpg", "front.jpg", "cover.png", "folder.png", "front.png"] {
                    let path = url.deletingLastPathComponent().appendingPathComponent(name)
                    if let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1_024 * 1_024,
                       let data = try? Data(contentsOf: path), NSImage(data: data) != nil {
                        results.append(("Local folder", name, data))
                    }
                }
            }
            if results.isEmpty, let path = track.artworkPath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                results.append(("Library artwork", "Cached cover", data))
            }
            return results
        }.value
    }

    nonisolated private static func metadataAlbumID(for track: TrackRecord, source: SourceRecord, cueFolder: URL?) -> String {
        guard let file = track.url else { return track.albumID }
        var folder = (cueFolder ?? file.deletingLastPathComponent()).standardizedFileURL
        if cueFolder == nil && folder.lastPathComponent.range(of: #"^(?:cd|disc|disk)[\s._-]*\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            folder = folder.deletingLastPathComponent()
        }
        guard let sourceURL = source.url?.standardizedFileURL else { return track.albumID }
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory)
        let root = (isDirectory.boolValue ? sourceURL : sourceURL.deletingLastPathComponent()).path
        let relative = folder.path.hasPrefix(root + "/") ? String(folder.path.dropFirst(root.count + 1)) : folder.path == root ? "." : folder.path
        return StableID.make(source.id, track.albumArtist, track.album, relative)
    }
}
