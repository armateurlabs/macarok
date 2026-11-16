import CryptoKit
import Foundation

public struct LibraryScanResult: Sendable {
    public var sourceID: String
    public var tracks: [TrackRecord]
    public var filesScanned: Int
    public var warnings: [String]
    public var isComplete: Bool
    public var scannedAt: Date
    public var fileCacheEntries: [LocalScanFileCacheEntry] = []
    public var filesRead: Int = 0
    public var coverage: LocalScanCoverage = .all

    public var activeIDs: Set<String> { Set(tracks.map(\.id)) }
    public var trackCount: Int { tracks.count }
}

public enum LibraryScannerError: LocalizedError {
    case unsupportedSource
    case missingDirectory
    case inaccessibleDirectory

    public var errorDescription: String? {
        switch self {
        case .unsupportedSource: "This scanner accepts local file sources only."
        case .missingDirectory: "The selected music directory is unavailable."
        case .inaccessibleDirectory: "Macarok could not read the selected music directory."
        }
    }
}

public struct LibraryScanner: Sendable {
    public static let supportedExtensions: Set<String> = ["mp3", "flac", "ogg", "oga", "opus", "m4a", "mp4", "aac", "wav", "aif", "aiff", "ape", "wv"]
    public let artworkCacheURL: URL

    public init(artworkCacheURL: URL = LibraryStore.defaultURL.deletingLastPathComponent().appendingPathComponent("Artwork", isDirectory: true)) {
        self.artworkCacheURL = artworkCacheURL
    }

    public func scan(source: SourceRecord,
                     cachedFiles: [String: LocalScanFileCacheEntry] = [:],
                     coverage: LocalScanCoverage = .all,
                     metadataReader: @escaping @Sendable (URL) throws -> AudioFileMetadata,
                     progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> LibraryScanResult {
        let task = Task.detached(priority: .background) {
            try performScan(source: source, cachedFiles: cachedFiles, coverage: coverage,
                            metadataReader: metadataReader, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performScan(source: SourceRecord,
                             cachedFiles: [String: LocalScanFileCacheEntry],
                             coverage requestedCoverage: LocalScanCoverage,
                             metadataReader: @Sendable (URL) throws -> AudioFileMetadata,
                             progress: (@Sendable (Int, Int) -> Void)?) throws -> LibraryScanResult {
        guard source.kind == .local else { throw LibraryScannerError.unsupportedSource }
        guard let sourceURL = source.url?.standardizedFileURL else { throw LibraryScannerError.missingDirectory }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw LibraryScannerError.missingDirectory
        }
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else { throw LibraryScannerError.inaccessibleDirectory }
        let directory = isDirectory.boolValue ? sourceURL : sourceURL.deletingLastPathComponent()
        // An explicit audio/CUE/playlist source has its own membership semantics.
        let coverage = isDirectory.boolValue ? requestedCoverage.normalized : .all

        let scanDate = Date()
        var warnings: [String] = []
        var isComplete = true
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        var audioFiles: [URL] = []
        var cueFiles: [URL] = []
        var playlistEntries: [PlaylistEntry]?
        if !isDirectory.boolValue {
            let ext = sourceURL.pathExtension.lowercased()
            if Self.supportedExtensions.contains(ext) {
                audioFiles = [sourceURL]
                if let cue = ["cue", "CUE"].map({ sourceURL.deletingPathExtension().appendingPathExtension($0) })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) }) { cueFiles = [cue] }
            } else if ["m3u", "m3u8", "pls"].contains(ext) {
                let entries = try PlaylistIO.read(url: sourceURL)
                playlistEntries = entries
                audioFiles = entries.map(\.url).filter { $0.isFileURL && Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
                audioFiles = audioFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
                cueFiles = entries.map(\.url).filter { $0.isFileURL && $0.pathExtension.lowercased() == "cue" }
                for cue in cueFiles {
                    do {
                        for name in try CUEParser.read(url: cue).fileNames {
                            let normalized = name.replacingOccurrences(of: "\\", with: "/")
                            let parent = cue.deletingLastPathComponent()
                            let candidate = parent.appendingPathComponent(normalized).standardizedFileURL
                            let sibling = parent.appendingPathComponent((normalized as NSString).lastPathComponent).standardizedFileURL
                            if FileManager.default.fileExists(atPath: candidate.path) { audioFiles.append(candidate) }
                            else if FileManager.default.fileExists(atPath: sibling.path) { audioFiles.append(sibling) }
                        }
                    } catch {
                        warnings.append("\(cue.lastPathComponent): \(error.localizedDescription)")
                        isComplete = false
                    }
                }
                // An explicitly opened playlist still presents a continuous album as its CUE tracks.
                for file in audioFiles {
                    let base = file.deletingPathExtension()
                    guard !cueFiles.contains(where: { $0.deletingPathExtension().path == base.path }) else { continue }
                    if let cue = ["cue", "CUE"].map({ base.appendingPathExtension($0) })
                        .first(where: { FileManager.default.fileExists(atPath: $0.path) }) { cueFiles.append(cue) }
                }
            } else if ext == "cue" {
                cueFiles = [sourceURL]
                let sheet = try CUEParser.read(url: sourceURL)
                for name in sheet.fileNames {
                    let normalized = name.replacingOccurrences(of: "\\", with: "/")
                    let candidate = directory.appendingPathComponent(normalized).standardizedFileURL
                    let sibling = directory.appendingPathComponent((normalized as NSString).lastPathComponent).standardizedFileURL
                    if FileManager.default.fileExists(atPath: candidate.path) { audioFiles.append(candidate) }
                    else if FileManager.default.fileExists(atPath: sibling.path) { audioFiles.append(sibling) }
                }
            } else { throw LibraryScannerError.unsupportedSource }
        } else {
            let roots: [URL]
            switch coverage {
            case .all: roots = [directory]
            case let .folders(paths): roots = paths.map { directory.appendingPathComponent($0, isDirectory: true) }
            }
            for root in roots {
                try Task.checkCancellation()
                var link = false
                var ancestor = root
                while ancestor.path != directory.path {
                    if (try? FileManager.default.attributesOfItem(atPath: ancestor.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                        link = true
                        break
                    }
                    let parent = ancestor.deletingLastPathComponent()
                    if parent.path == ancestor.path { break }
                    ancestor = parent
                }
                if link { continue }
                let attributes: [FileAttributeKey: Any]
                do { attributes = try FileManager.default.attributesOfItem(atPath: root.path) }
                catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                    [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                    // A removed/renamed folder is a complete empty result for that coverage.
                    continue
                } catch {
                    warnings.append("\(root.lastPathComponent): \(error.localizedDescription)")
                    isComplete = false
                    continue
                }
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                    warnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    isComplete = false
                    return true
                }) else {
                    warnings.append("\(root.lastPathComponent): the directory could not be read.")
                    isComplete = false
                    continue
                }
                for case let file as URL in enumerator {
                    try Task.checkCancellation()
                    let values: URLResourceValues
                    do { values = try file.resourceValues(forKeys: keys) }
                    catch {
                        warnings.append("\(file.lastPathComponent): file information could not be read (\(error.localizedDescription)).")
                        isComplete = false
                        continue
                    }
                    if values.isSymbolicLink == true { continue }
                    guard values.isRegularFile == true else { continue }
                    let ext = file.pathExtension.lowercased()
                    if Self.supportedExtensions.contains(ext) { audioFiles.append(file.standardizedFileURL) }
                    if ext == "cue" { cueFiles.append(file.standardizedFileURL) }
                }
            }
        }
        audioFiles = Array(Set(audioFiles))
        audioFiles.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        cueFiles = Array(Set(cueFiles))
        cueFiles.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var parsedSheets: [String: CUESheet] = [:]
        var cueCacheEntries: [LocalScanFileCacheEntry] = []
        for cue in cueFiles {
            try Task.checkCancellation()
            do {
                let before = try? LocalScanFileFingerprint(url: cue)
                let sheet = try CUEParser.read(url: cue)
                parsedSheets[cue.path] = sheet
                if let before, before == (try? LocalScanFileFingerprint(url: cue)) {
                    // Preserve missing FILE references too, for a later watcher event in their folder.
                    cueCacheEntries.append(LocalScanFileCacheEntry(path: cue.path, byteCount: before.byteCount,
                        modifiedAt: before.modifiedAt, metadata: AudioFileMetadata(embeddedCueSheet: sheet.originalText)))
                }
                if coverage != .all {
                    for name in sheet.fileNames {
                        let normalized = name.replacingOccurrences(of: "\\", with: "/")
                        let candidate = cue.deletingLastPathComponent().appendingPathComponent(normalized).standardizedFileURL
                        let sibling = cue.deletingLastPathComponent().appendingPathComponent((normalized as NSString).lastPathComponent).standardizedFileURL
                        if [candidate, sibling].contains(where: {
                            FileManager.default.fileExists(atPath: $0.path) && !coverage.contains(url: $0, rootURL: directory)
                        }) {
                            return try performScan(source: source, cachedFiles: cachedFiles, coverage: .all,
                                metadataReader: metadataReader, progress: progress)
                        }
                    }
                }
            } catch {
                warnings.append("\(cue.lastPathComponent): \(error.localizedDescription)")
                isComplete = false
            }
        }
        let filesByPath = Dictionary(uniqueKeysWithValues: audioFiles.map { ($0.path, $0) })
        let foldedPaths = Dictionary(grouping: audioFiles, by: { $0.path.lowercased() })
        var metadataCache: [String: AudioFileMetadata] = [:]
        var failedMetadataFiles = Set<String>()
        var updatedCache: [LocalScanFileCacheEntry] = cueCacheEntries
        var filesRead = 0
        var lastProgressAt = -Double.infinity
        var artworkCache: [String: String?] = [:]
        var coveredFiles = Set<String>()
        var tracks: [TrackRecord] = []

        func publishProgress(final: Bool = false) {
            let now = ProcessInfo.processInfo.systemUptime
            guard final || now - lastProgressAt >= 0.1 else { return }
            lastProgressAt = now
            progress?(metadataCache.count, audioFiles.count)
        }

        func readMetadata(for file: URL) -> AudioFileMetadata {
            if let cached = metadataCache[file.path] { return cached }
            let fingerprint = try? LocalScanFileFingerprint(url: file)
            if let fingerprint, let cached = cachedFiles[file.path], cached.matches(fingerprint) {
                metadataCache[file.path] = cached.metadata
                updatedCache.append(cached)
                publishProgress()
                return cached.metadata
            }
            var value: AudioFileMetadata
            var readSucceeded = false
            do { filesRead += 1; value = try metadataReader(file); readSucceeded = true }
            catch {
                warnings.append("\(file.lastPathComponent): metadata could not be read (\(error.localizedDescription)).")
                isComplete = false
                failedMetadataFiles.insert(file.path)
                value = AudioFileMetadata()
            }
            if let data = value.artworkData, !data.isEmpty {
                if value.artworkPath == nil {
                    do { value.artworkPath = try cacheArtwork(data: data, mimeType: value.artworkMIMEType) }
                    catch { warnings.append("\(file.lastPathComponent): embedded artwork could not be cached.") }
                }
                // Keep only a cache reference while indexing a large collection.
                value.artworkData = nil
            }
            metadataCache[file.path] = value
            // Do not cache a failed read or metadata from a file replaced while TagLib was reading it.
            if readSucceeded {
                if let fingerprint, fingerprint == (try? LocalScanFileFingerprint(url: file)) {
                    updatedCache.append(LocalScanFileCacheEntry(path: file.path, byteCount: fingerprint.byteCount,
                        modifiedAt: fingerprint.modifiedAt, metadata: value))
                } else {
                    warnings.append("\(file.lastPathComponent): the file changed while its metadata was being read.")
                    isComplete = false
                    failedMetadataFiles.insert(file.path)
                }
            }
            publishProgress()
            return value
        }

        func artwork(for file: URL, metadata: AudioFileMetadata) -> String? {
            if let path = metadata.artworkPath, FileManager.default.fileExists(atPath: path) { return path }
            if let data = metadata.artworkData, !data.isEmpty {
                do { return try cacheArtwork(data: data, mimeType: metadata.artworkMIMEType) }
                catch { warnings.append("\(file.lastPathComponent): embedded artwork could not be cached.") }
            }
            let folder = file.deletingLastPathComponent().path
            if let cached = artworkCache[folder] { return cached }
            let path = localArtwork(in: file.deletingLastPathComponent())
            artworkCache[folder] = .some(path)
            return path
        }

        func relativePath(for file: URL) -> String {
            if file.path == directory.path { return "." }
            let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
            return file.path.hasPrefix(prefix) ? String(file.path.dropFirst(prefix.count)) : file.path
        }

        func baseTrack(file: URL, metadata: AudioFileMetadata) -> TrackRecord {
            let parent = file.deletingLastPathComponent()
            let parentParent = parent.deletingLastPathComponent()
            let fallbackArtist = parentParent.path == directory.path || parent.path == directory.path ? "Unknown Artist" : parentParent.lastPathComponent
            let artist = nonempty(metadata.artist) ?? nonempty(metadata.albumArtist) ?? fallbackArtist
            let albumArtist = nonempty(metadata.albumArtist) ?? artist
            let album = nonempty(metadata.album) ?? (parent.path == directory.path ? "Unknown Album" : parent.lastPathComponent)
            let filename = file.deletingPathExtension().lastPathComponent
            let fallbackTitle = filename.replacingOccurrences(of: #"^\d+[\s._-]+"#, with: "", options: .regularExpression)
            let format = nonempty(metadata.format) ?? file.pathExtension.uppercased()
            var albumFolder = parent
            if parent.lastPathComponent.range(of: #"^(?:cd|disc|disk)[\s._-]*\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                albumFolder = parentParent
            }
            return TrackRecord(id: StableID.make(source.id, relativePath(for: file)), sourceID: source.id,
                               albumID: StableID.make(source.id, albumArtist, album, relativePath(for: albumFolder)),
                               title: nonempty(metadata.title) ?? nonempty(fallbackTitle) ?? filename,
                               artist: artist, albumArtist: albumArtist, album: album, year: metadata.year,
                               genre: metadata.genre, trackNumber: metadata.trackNumber, discNumber: metadata.discNumber,
                               duration: metadata.duration ?? 0, fileURL: file.absoluteString,
                               format: format, artworkPath: artwork(for: file, metadata: metadata), addedAt: scanDate)
        }

        func resolve(_ fileName: String, relativeTo cue: URL) -> URL? {
            let normalized = fileName.replacingOccurrences(of: "\\", with: "/")
            let candidate = cue.deletingLastPathComponent().appendingPathComponent(normalized).standardizedFileURL
            if let actual = filesByPath[candidate.path] { return actual }
            if let matches = foldedPaths[candidate.path.lowercased()], matches.count == 1 { return matches[0] }
            // A CUE created on another OS can retain an absolute path. Only try its local sibling.
            let sibling = cue.deletingLastPathComponent().appendingPathComponent((normalized as NSString).lastPathComponent).standardizedFileURL
            if let actual = filesByPath[sibling.path] { return actual }
            if let matches = foldedPaths[sibling.path.lowercased()], matches.count == 1 { return matches[0] }
            return nil
        }

        func appendSheet(_ sheet: CUESheet, cue: URL, embeddedFile: URL? = nil) {
            let alreadyCovered = coveredFiles
            var resolved: [(CUETrack, URL)] = []
            for track in sheet.tracks {
                guard let file = embeddedFile ?? resolve(track.fileName, relativeTo: cue) else {
                    warnings.append("\(cue.lastPathComponent): referenced file “\(track.fileName)” is unavailable.")
                    isComplete = false
                    continue
                }
                if alreadyCovered.contains(file.path) { continue }
                resolved.append((track, file))
            }
            for (offset, pair) in resolved.enumerated() {
                let (cueTrack, file) = pair
                let metadata = readMetadata(for: file)
                guard !failedMetadataFiles.contains(file.path) else { continue }
                var track = baseTrack(file: file, metadata: metadata)
                let start = cueTrack.index01.seconds
                let next = resolved.dropFirst(offset + 1).first { $0.1.path == file.path }?.0.index01.seconds
                let end = next ?? metadata.duration
                if let end, end > 0, (end <= start || (metadata.duration ?? end) + 0.05 < end) {
                    warnings.append("\(cue.lastPathComponent): track \(cueTrack.number) has boundaries outside the audio file.")
                    isComplete = false
                    continue
                }
                if let duration = metadata.duration, duration > 0, start >= duration {
                    warnings.append("\(cue.lastPathComponent): track \(cueTrack.number) starts beyond the audio file.")
                    isComplete = false
                    continue
                }
                track.id = StableID.make(source.id, relativePath(for: file), "cue", String(cueTrack.number))
                track.title = nonempty(cueTrack.title) ?? String(format: "Track %02d", cueTrack.number)
                track.artist = nonempty(cueTrack.performer) ?? nonempty(sheet.performer) ?? track.artist
                track.albumArtist = nonempty(sheet.performer) ?? track.albumArtist
                track.album = nonempty(sheet.title) ?? track.album
                track.year = sheet.year ?? track.year
                track.genre = sheet.genre ?? track.genre
                track.albumID = StableID.make(source.id, track.albumArtist, track.album, relativePath(for: cue.deletingLastPathComponent()))
                track.trackNumber = cueTrack.number
                track.cuePath = embeddedFile == nil ? cue.path : nil
                track.startTime = start
                track.endTime = end
                track.duration = end.map { max(0, $0 - start) } ?? 0
                tracks.append(track)
                coveredFiles.insert(file.path)
            }
        }

        for cue in cueFiles {
            try Task.checkCancellation()
            if let sheet = parsedSheets[cue.path] { appendSheet(sheet, cue: cue) }
        }

        for file in audioFiles {
            try Task.checkCancellation()
            guard !coveredFiles.contains(file.path) else { continue }
            let metadata = readMetadata(for: file)
            guard !failedMetadataFiles.contains(file.path) else { continue }
            if let text = nonempty(metadata.embeddedCueSheet) {
                do {
                    let hasFile = text.range(of: #"(?im)^\s*FILE\s"#, options: .regularExpression) != nil
                    let input = hasFile ? text : "FILE \"\(file.lastPathComponent)\" WAVE\n" + text
                    let sheet = try CUEParser.parse(input)
                    if sheet.fileNames.count <= 1 { appendSheet(sheet, cue: file, embeddedFile: file) }
                    else { warnings.append("\(file.lastPathComponent): an embedded CUE sheet must reference one audio file."); isComplete = false }
                } catch { warnings.append("\(file.lastPathComponent): embedded CUE could not be read (\(error.localizedDescription))."); isComplete = false }
            } else if let points = metadata.cuePoints, !points.isEmpty {
                let ordered = points.sorted { $0.startSample < $1.startSample }
                for (index, point) in ordered.enumerated() where point.sampleRate > 0 && point.startSample >= 0 {
                    var track = baseTrack(file: file, metadata: metadata)
                    let start = Double(point.startSample) / Double(point.sampleRate)
                    let endSample = point.endSample ?? (ordered.indices.contains(index + 1) ? ordered[index + 1].startSample : nil)
                    let end = endSample.map { Double($0) / Double(point.sampleRate) } ?? metadata.duration
                    guard end == nil || end! > start else { continue }
                    track.id = StableID.make(source.id, relativePath(for: file), "cue", String(point.number))
                    track.title = point.title ?? String(format: "Track %02d", point.number)
                    track.artist = point.artist ?? track.artist
                    track.trackNumber = point.number
                    track.startTime = start
                    track.endTime = end
                    track.duration = end.map { $0 - start } ?? 0
                    tracks.append(track)
                    coveredFiles.insert(file.path)
                }
            }
            if !coveredFiles.contains(file.path) { tracks.append(baseTrack(file: file, metadata: metadata)) }
        }

        if let entries = playlistEntries {
            var indexed: [String: TrackRecord] = [:]
            for entry in entries where entry.url.isFileURL {
                if entry.url.pathExtension.lowercased() == "cue" {
                    for track in tracks where track.cuePath == entry.url.standardizedFileURL.path { indexed[track.id] = track }
                    continue
                }
                let matching = tracks.filter { $0.url?.standardizedFileURL.path == entry.url.standardizedFileURL.path }
                guard var track = matching.first else { continue }
                if entry.startTime != nil || entry.endTime != nil {
                    if let exact = matching.first(where: { abs(($0.startTime ?? 0) - (entry.startTime ?? 0)) < 0.000_001 && $0.endTime == entry.endTime }) {
                        indexed[exact.id] = exact
                        continue
                    }
                    let start = entry.startTime ?? 0
                    let physicalDuration = metadataCache[entry.url.path]?.duration ?? track.duration
                    let end = entry.endTime ?? (physicalDuration > 0 ? physicalDuration : nil)
                    guard start >= 0, end == nil || end! > start else { continue }
                    track.id = StableID.make(source.id, relativePath(for: entry.url), "segment", String(start), end.map { String($0) } ?? "")
                    track.startTime = start
                    track.endTime = end
                    track.duration = end.map { $0 - start } ?? entry.duration ?? 0
                    if let title = nonempty(entry.title) { track.title = title }
                    indexed[track.id] = track
                } else {
                    for value in matching { indexed[value.id] = value }
                }
            }
            tracks = Array(indexed.values)
        }
        try Task.checkCancellation()
        publishProgress(final: true)
        return LibraryScanResult(sourceID: source.id, tracks: tracks.sorted(by: TrackRecord.libraryOrder),
                                 filesScanned: metadataCache.count, warnings: warnings,
                                 isComplete: isComplete, scannedAt: scanDate,
                                 fileCacheEntries: updatedCache, filesRead: filesRead, coverage: coverage)
    }

    private func cacheArtwork(data: Data, mimeType: String?) throws -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let isPNG = mimeType?.lowercased().contains("png") == true || data.starts(with: [0x89, 0x50, 0x4e, 0x47])
        let ext = isPNG ? "png" : "jpg"
        let url = artworkCacheURL.appendingPathComponent(digest).appendingPathExtension(ext)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: artworkCacheURL, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return url.path
    }

    private func localArtwork(in folder: URL) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        for name in ["cover", "folder", "front", "album"] {
            for ext in ["jpg", "jpeg", "png"] {
                if let file = files.first(where: { $0.lastPathComponent.lowercased() == "\(name).\(ext)" }) { return file.path }
            }
        }
        return nil
    }

    private func nonempty(_ string: String?) -> String? {
        guard let value = string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
