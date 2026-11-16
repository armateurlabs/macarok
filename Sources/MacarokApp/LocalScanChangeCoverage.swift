import Foundation
import MacarokCore

extension DirectoryChangeBatch {
    /// Resolve on the watcher queue before hopping to the foreground. Directory flags survive
    /// deletion/rename; unknown missing paths conservatively rescan their parent.
    func scanCoverage(root: URL) -> LocalScanCoverage? {
        guard !mustRescan, !paths.isEmpty else { return .all }
        let root = root.standardizedFileURL
        var folders: [String] = []
        event: for rawPath in Set(paths) {
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            guard let relative = LocalScanCoverage.relativePath(url, rootURL: root) else { continue }
            if relative.isEmpty { return .all }
            // These entries are excluded by the scanner as well.
            if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            var ancestor = url.deletingLastPathComponent()
            while ancestor.path != root.path, LocalScanCoverage.relativePath(ancestor, rootURL: root) != nil {
                if (try? ancestor.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { continue event }
                ancestor.deleteLastPathComponent()
            }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            let knownDirectory = directoryPaths.contains(rawPath) || directoryPaths.contains(url.path)
            let knownFile = filePaths.contains(rawPath) || filePaths.contains(url.path) || (exists && !isDirectory.boolValue)
            let folder: URL
            if knownDirectory || (exists && isDirectory.boolValue) {
                folder = url
            } else {
                let ext = url.pathExtension.lowercased()
                let artwork = ["jpg", "jpeg", "png"].contains(ext) &&
                    ["cover", "folder", "front", "album"].contains(url.deletingPathExtension().lastPathComponent.lowercased())
                let relevant = LibraryScanner.supportedExtensions.contains(ext) || ["cue", "m3u", "m3u8", "pls"].contains(ext) || artwork
                if !relevant && knownFile { continue }
                // An untyped absent directory can have a dotted name. Do not mistake it for an
                // irrelevant deleted file and leave stale descendants in the index.
                folder = url.deletingLastPathComponent()
            }
            guard let path = LocalScanCoverage.relativePath(folder, rootURL: root) else { continue }
            if path.isEmpty { return .all }
            folders.append(path)
        }
        return folders.isEmpty ? nil : LocalScanCoverage.folders(folders).normalized
    }
}
