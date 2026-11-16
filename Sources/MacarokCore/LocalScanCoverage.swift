import Foundation
import GRDB

/// Recursive directories relative to the selected source root. A narrow scan must never
/// reconcile unrelated tracks or cache rows as missing.
public enum LocalScanCoverage: Equatable, Sendable {
    case all
    case folders([String])

    public var normalized: LocalScanCoverage {
        guard case let .folders(paths) = self else { return .all }
        var result: [String] = []
        for raw in paths {
            guard !raw.hasPrefix("/"), !raw.split(separator: "/").contains("..") else { return .all }
            let path = raw.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
            if path.isEmpty { return .all }
            result.append(path)
        }
        result.sort()
        var roots: [String] = []
        for path in result where !roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            roots.append(path)
        }
        // Bound SQL parameters and pathological watcher batches; one full scan is cheaper.
        if roots.count > 128 { return .all }
        return .folders(roots)
    }

    public func merged(with other: LocalScanCoverage) -> LocalScanCoverage {
        guard case let .folders(left) = normalized, case let .folders(right) = other.normalized else { return .all }
        return LocalScanCoverage.folders(left + right).normalized
    }

    public func contains(relativePath: String) -> Bool {
        switch normalized {
        case .all: return true
        case let .folders(paths): return paths.contains { relativePath == $0 || relativePath.hasPrefix($0 + "/") }
        }
    }

    public func contains(url: URL, rootURL: URL) -> Bool {
        guard let relative = Self.relativePath(url, rootURL: rootURL) else { return false }
        return contains(relativePath: relative)
    }

    public static func relativePath(_ url: URL, rootURL: URL) -> String? {
        let root = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    /// Path and URL columns use binary ranges, avoiding LIKE's case folding and wildcard rules.
    /// Every prefix ends with '/', whose immediate binary successor is '0'.
    func predicate(column: String, rootURL: URL, encodedURL: Bool = false) -> (sql: String, arguments: [String]) {
        guard case let .folders(paths) = normalized else { return ("1", []) }
        var clauses: [String] = []
        var arguments: [String] = []
        for path in paths {
            let folder = rootURL.appendingPathComponent(path, isDirectory: true).standardizedFileURL
            let raw = encodedURL ? folder.absoluteString : folder.path
            let prefix = raw.hasSuffix("/") ? raw : raw + "/"
            clauses.append("(\(column) >= ? AND \(column) < ?)")
            arguments += [prefix, String(prefix.dropLast()) + "0"]
        }
        return (clauses.isEmpty ? "0" : clauses.joined(separator: " OR "), arguments)
    }
}

extension LibraryStore {
    /// Expand already indexed CUE/audio dependencies before loading a bounded metadata cache.
    /// New cross-folder sheets are detected by LibraryScanner, which safely falls back to all.
    public func localScanCoverage(sourceID: String, requested: LocalScanCoverage,
                                  rootURL: URL? = nil) throws -> LocalScanCoverage {
        let requested = requested.normalized
        guard case .folders = requested else { return .all }
        return try database.read { db in
            guard let source = try SourceRecord.fetchOne(db, key: sourceID), source.kind == .local,
                  let root = rootURL ?? source.url else { return .all }
            if let previous = source.url, root.standardizedFileURL.path != previous.standardizedFileURL.path {
                // Old file URLs/cache paths must be reconciled too after a bookmark relocation.
                return .all
            }
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), !directory.boolValue { return .all }
            var coverage = requested
            // A CUE may reference audio in another directory, which can itself be shared by a sheet.
            // Reaching the source root collapses to a single full scan automatically.
            for _ in 0..<64 {
                try Task.checkCancellation()
                let audio = coverage.predicate(column: "fileURL", rootURL: root, encodedURL: true)
                let cue = coverage.predicate(column: "cuePath", rootURL: root)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT DISTINCT fileURL, cuePath FROM tracks
                    WHERE sourceID = ? AND cuePath IS NOT NULL AND ((\(audio.sql)) OR (\(cue.sql)))
                    """, arguments: StatementArguments([sourceID] + audio.arguments + cue.arguments))
                var folders: [String] = []
                var dependencies: [URL] = []
                for row in rows {
                    let file: String? = row["fileURL"]
                    let sheet: String? = row["cuePath"]
                    dependencies += [file.flatMap(URL.init(string:)), sheet.map { URL(fileURLWithPath: $0) }].compactMap { $0 }
                }
                let cachedAudio = coverage.predicate(column: "audioPath", rootURL: root)
                let cachedCue = coverage.predicate(column: "cuePath", rootURL: root)
                let references = try Row.fetchAll(db, sql: """
                    SELECT cuePath, audioPath FROM localScanCUEReferences
                    WHERE sourceID = ? AND ((\(cachedAudio.sql)) OR (\(cachedCue.sql)))
                    """, arguments: StatementArguments([sourceID] + cachedAudio.arguments + cachedCue.arguments))
                for row in references {
                    dependencies.append(URL(fileURLWithPath: row["cuePath"] as String))
                    dependencies.append(URL(fileURLWithPath: row["audioPath"] as String))
                }
                for url in dependencies {
                    guard let path = LocalScanCoverage.relativePath(url.deletingLastPathComponent(), rootURL: root) else {
                        // A legacy playlist can refer outside the source; narrow reconciliation is unsafe.
                        return .all
                    }
                    folders.append(path)
                }
                let expanded = coverage.merged(with: .folders(folders))
                if expanded == coverage { return coverage }
                coverage = expanded
                if coverage == .all { return .all }
            }
            return .all
        }
    }
}
