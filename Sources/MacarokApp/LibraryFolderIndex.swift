import Foundation
import MacarokCore

struct FolderNode: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let children: [FolderNode]?
}

/// Source roots are resolved once; individual track paths require no filesystem access.
struct LibraryFolderPathResolver: Sendable {
    private let localBases: [String: String]

    init(sources: [SourceRecord], isDirectory: (URL) -> Bool = { url in
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }) {
        var bases: [String: String] = [:]
        for source in sources where source.kind == .local {
            guard let url = source.url, url.isFileURL else { continue }
            let base = isDirectory(url) || url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            bases[source.id] = base.standardizedFileURL.path
        }
        localBases = bases
    }

    func folderPath(_ track: TrackRecord) -> String {
        if let path = track.remotePath, !path.isEmpty {
            return (Self.normalize(path) as NSString).deletingLastPathComponent
        }
        guard let url = track.url, url.isFileURL else { return "" }
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        guard let base = localBases[track.sourceID] else { return Self.normalize(parent.lastPathComponent) }
        if parent.path == base { return "" }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        if parent.path.hasPrefix(prefix) { return Self.normalize(String(parent.path.dropFirst(prefix.count))) }
        // Explicit playlists can reference files outside their own directory.
        return Self.normalize(parent.path)
    }

    static func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").filter { $0 != "." }.joined(separator: "/")
    }
}

enum LibraryFolderIndex {
    /// Each track is resolved once. Tree assembly visits only the distinct folder prefixes.
    static func build(tracks: [TrackRecord], sources: [SourceRecord], rootName: String) throws -> [FolderNode] {
        try Task.checkCancellation()
        let resolver = LibraryFolderPathResolver(sources: sources)
        var names: [String: String] = [:]
        var descendants: [String: [String]] = [:]
        for track in tracks {
            try Task.checkCancellation()
            let path = resolver.folderPath(track)
            var parent = ""
            for component in path.split(separator: "/") {
                let name = String(component)
                let id = parent.isEmpty ? name : parent + "/" + name
                if names[id] == nil {
                    names[id] = name
                    descendants[parent, default: []].append(id)
                }
                parent = id
            }
        }
        func node(_ id: String, name: String) throws -> FolderNode {
            try Task.checkCancellation()
            let children = try (descendants[id] ?? []).sorted { names[$0, default: ""] < names[$1, default: ""] }
                .map { try node($0, name: names[$0, default: ""]) }
            return FolderNode(id: id, name: name, children: children.isEmpty ? nil : children)
        }
        return [try node("", name: rootName)]
    }
}
