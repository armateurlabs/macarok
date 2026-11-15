import Foundation
import MacarokCore

struct PreparedLocalPlayback: Sendable {
    let url: URL
    let renewedSource: SourceRecord?
}

/// Foundation access is injectable so preparation and security-scope lifetimes can be tested without UI or sandbox prompts.
struct PlaybackPreparationEnvironment: Sendable {
    var resolveBookmark: @Sendable (Data) throws -> (url: URL, stale: Bool)
    var makeBookmark: @Sendable (URL) throws -> Data
    var startAccess: @Sendable (URL) -> Bool
    var stopAccess: @Sendable (URL) -> Void
    var isDirectory: @Sendable (URL) -> Bool
    var isReadableFile: @Sendable (URL) -> Bool

    static let live = PlaybackPreparationEnvironment(resolveBookmark: { data in
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }, makeBookmark: { try $0.bookmarkData(options: .withSecurityScope) },
       startAccess: { $0.startAccessingSecurityScopedResource() },
       stopAccess: { $0.stopAccessingSecurityScopedResource() },
       isDirectory: { url in
           var directory: ObjCBool = false
           return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
       }, isReadableFile: { url in
           var directory: ObjCBool = false
           return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue &&
               FileManager.default.isReadableFile(atPath: url.path)
       })
}

/// Resolves bookmarks and probes local files away from MainActor. Cached security access remains
/// open while VLC reads a prepared URL, until the playback owner explicitly invalidates it.
actor PlaybackPreparationWorker {
    private struct Access {
        let sourceLocation: String
        let originalBookmark: Data?
        let url: URL
        let isDirectory: Bool
        let ownsSecurityScope: Bool
        let renewedSource: SourceRecord?
    }

    private let environment: PlaybackPreparationEnvironment
    private var access: [String: Access] = [:]

    init(environment: PlaybackPreparationEnvironment = .live) { self.environment = environment }

    /// Scans, watchers, and file editors share the same off-main bookmark resolution and access lifetime.
    func resolveSource(_ source: SourceRecord) throws -> PreparedLocalPlayback {
        let resolved = try resolveAccess(source)
        try Task.checkCancellation()
        return PreparedLocalPlayback(url: resolved.url, renewedSource: resolved.renewedSource)
    }

    func prepare(source: SourceRecord, track: TrackRecord) throws -> PreparedLocalPlayback {
        try Task.checkCancellation()
        guard source.kind == .local, track.sourceID == source.id, let originalRoot = source.url, originalRoot.isFileURL else {
            throw AppFailure.missingSource
        }
        guard let recordedURL = track.url, recordedURL.isFileURL else { throw AppFailure.missingFile }
        let resolved = try resolveAccess(source)
        try Task.checkCancellation()
        let oldRoot = originalRoot.standardizedFileURL
        let oldFile = recordedURL.standardizedFileURL
        var url = oldFile
        if resolved.url.path != oldRoot.path {
            if !resolved.isDirectory, oldFile.path == oldRoot.path {
                // An explicitly opened audio file may have been moved or renamed by Finder.
                url = resolved.url
            } else {
                let oldDirectory = resolved.isDirectory ? oldRoot : oldRoot.deletingLastPathComponent()
                let newDirectory = resolved.isDirectory ? resolved.url : resolved.url.deletingLastPathComponent()
                let prefix = oldDirectory.path.hasSuffix("/") ? oldDirectory.path : oldDirectory.path + "/"
                if oldFile.path.hasPrefix(prefix) {
                    url = newDirectory.appendingPathComponent(String(oldFile.path.dropFirst(prefix.count))).standardizedFileURL
                }
            }
        }
        try Task.checkCancellation()
        guard environment.isReadableFile(url) else { throw AppFailure.missingFile }
        try Task.checkCancellation()
        return PreparedLocalPlayback(url: url, renewedSource: resolved.renewedSource)
    }

    /// The owner stops VLC before invalidating a source that is currently playing.
    func invalidate(sourceIDs: Set<String>) {
        for id in sourceIDs { release(sourceID: id) }
    }

    func shutdown() {
        for id in Array(access.keys) { release(sourceID: id) }
    }

    private func resolveAccess(_ source: SourceRecord) throws -> Access {
        try Task.checkCancellation()
        guard source.kind == .local, let originalRoot = source.url, originalRoot.isFileURL else { throw AppFailure.missingSource }
        if let cached = access[source.id], cached.sourceLocation == source.location,
           source.bookmarkData == cached.originalBookmark || cached.renewedSource.map({ source.bookmarkData == $0.bookmarkData }) == true {
            return cached
        }
        release(sourceID: source.id)
        var root = originalRoot
        var renewedSource: SourceRecord?
        if let bookmark = source.bookmarkData, let bookmarkRoot = try? environment.resolveBookmark(bookmark) {
            root = bookmarkRoot.url
            if bookmarkRoot.stale, let data = try? environment.makeBookmark(root) {
                var renewed = source
                renewed.bookmarkData = data
                renewedSource = renewed
            }
        }
        try Task.checkCancellation()
        guard root.isFileURL else { throw AppFailure.missingFile }
        let ownsScope = environment.startAccess(root)
        let value = Access(sourceLocation: source.location, originalBookmark: source.bookmarkData,
            url: root.standardizedFileURL, isDirectory: environment.isDirectory(root),
            ownsSecurityScope: ownsScope, renewedSource: renewedSource)
        access[source.id] = value
        return value
    }

    private func release(sourceID: String) {
        if let previous = access.removeValue(forKey: sourceID), previous.ownsSecurityScope {
            environment.stopAccess(previous.url)
        }
    }
}
