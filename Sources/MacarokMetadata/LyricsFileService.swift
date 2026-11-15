import Foundation
import MacarokCore

public struct LyricsFileWriteError: LocalizedError {
    public let savedURLs: [URL]
    public let failedURL: URL
    public let reason: String

    public init(savedURLs: [URL], failedURL: URL, reason: String) {
        self.savedURLs = savedURLs; self.failedURL = failedURL; self.reason = reason
    }

    public var errorDescription: String? {
        let prefix = savedURLs.isEmpty ? "Lyrics were not saved." : "Some lyrics were saved; the cached lyrics are still available."
        return "\(prefix) \(failedURL.lastPathComponent): \(reason)"
    }
}

/// Synchronous file work; callers must run this service away from the foreground.
public enum LyricsFileService {
    private static let lock = NSRecursiveLock()
    private static let maximumSize = 2 * 1_024 * 1_024

    public static func read(track: TrackRecord) throws -> LyricsDocument? {
        lock.lock()
        defer { lock.unlock() }
        guard let audio = track.url, audio.isFileURL else { return nil }
        if track.isCUETrack {
            let base = cueTrackBase(track: track, audio: audio)
            for ext in ["lrc", "txt"] {
                if let document = try readSidecar(base.appendingPathExtension(ext)) { return document }
            }
            var bases = [audio.deletingPathExtension()]
            if let cue = cueURL(track), cue.deletingPathExtension() != bases[0] { bases.append(cue.deletingPathExtension()) }
            for base in bases {
                if let document = try readSidecar(base.appendingPathExtension("lrc")), document.isSynced {
                    let start = track.startTime ?? 0
                    let end = track.endTime ?? (track.duration > 0 ? start + track.duration : nil)
                    let segment = document.sliced(from: start, to: end)
                    if segment.hasContent { return segment }
                }
            }
            // Embedded synchronized lyrics may describe the shared album as well.
            if let text = try embedded(audio), !text.isEmpty {
                let document = LRCParser.parse(text, source: .embedded)
                if document.isSynced {
                    let start = track.startTime ?? 0
                    let segment = document.sliced(from: start, to: track.endTime ?? (track.duration > 0 ? start + track.duration : nil))
                    if segment.hasContent { return segment }
                }
            }
            return nil
        }
        for ext in ["lrc", "txt"] {
            if let document = try readSidecar(audio.deletingPathExtension().appendingPathExtension(ext)) { return document }
        }
        if let text = try embedded(audio) {
            let document = LRCParser.parse(text, source: .embedded)
            if document.hasContent { return document }
        }
        return nil
    }

    /// Commits tags first and reports partial success if a later sidecar write fails.
    @discardableResult
    public static func write(document: LyricsDocument, track: TrackRecord) throws -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        guard let audio = track.url, audio.isFileURL else {
            throw MetadataError.unsupported("Saving lyrics requires an original local audio file.")
        }
        guard document.hasContent, !document.isInstrumental else {
            throw MetadataError.unsupported("There are no lyrics to save.")
        }
        var saved: [URL] = []
        var destination = audio
        do {
            if track.isCUETrack {
                let base = cueTrackBase(track: track, audio: audio)
                destination = base.appendingPathExtension(document.isSynced ? "lrc" : "txt")
                try writeSidecar(document.lrcText ?? document.plainText, to: destination)
                saved.append(destination)
                // An old synchronized override must not win over a new plain-text correction.
                let stale = base.appendingPathExtension(document.isSynced ? "txt" : "lrc")
                if FileManager.default.fileExists(atPath: stale.path) {
                    destination = stale
                    try writeSidecar(document.lrcText ?? document.plainText, to: stale)
                    saved.append(stale)
                }
            } else {
                try TagLibMetadataService.write(properties: ["LYRICS": document.plainText], to: audio)
                saved.append(audio)
                let sidecar = audio.deletingPathExtension().appendingPathExtension("lrc")
                if document.isSynced || FileManager.default.fileExists(atPath: sidecar.path) {
                    destination = sidecar
                    try writeSidecar(document.lrcText ?? document.plainText, to: sidecar)
                    saved.append(sidecar)
                }
                let plainSidecar = audio.deletingPathExtension().appendingPathExtension("txt")
                if FileManager.default.fileExists(atPath: plainSidecar.path) {
                    destination = plainSidecar
                    try writeSidecar(document.plainText, to: plainSidecar)
                    saved.append(plainSidecar)
                }
            }
            return saved
        } catch {
            throw LyricsFileWriteError(savedURLs: saved, failedURL: destination, reason: error.localizedDescription)
        }
    }

    private static func cueURL(_ track: TrackRecord) -> URL? {
        guard let path = track.cuePath else { return nil }
        if let url = URL(string: path), url.scheme != nil { return url.isFileURL ? url : nil }
        return URL(fileURLWithPath: path)
    }

    private static func cueTrackBase(track: TrackRecord, audio: URL) -> URL {
        let base = (cueURL(track) ?? audio).deletingPathExtension()
        let suffix = track.trackNumber.flatMap { $0 > 0 ? String(format: "%02d", $0) : nil }
            ?? String(StableID.make(track.sourceID, track.id).prefix(12))
        return base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + ".track-" + suffix)
    }

    private static func embedded(_ audio: URL) throws -> String? {
        try TagLibMetadataService.properties(url: audio)["LYRICS"]?.first
    }

    private static func readSidecar(_ url: URL) throws -> LyricsDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= maximumSize else {
            throw MetadataError.unsupported("The lyrics file is larger than 2 MB.")
        }
        let data = try Data(contentsOf: url)
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { text = String(data: data, encoding: .utf16) }
        else { text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) }
        guard let text else { throw MetadataError.unsupported("The lyrics file's text encoding could not be read.") }
        let document = LRCParser.parse(text, source: .sidecar)
        return document.hasContent ? document : nil
    }

    private static func writeSidecar(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        guard data.count <= maximumSize else { throw MetadataError.unsupported("The lyrics are larger than 2 MB.") }
        try data.write(to: url, options: .atomic)
        guard try Data(contentsOf: url) == data else { throw MetadataError.verificationFailed("lyrics sidecar") }
    }
}
