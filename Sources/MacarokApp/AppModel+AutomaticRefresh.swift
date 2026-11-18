import Foundation
import MacarokCore

extension AppModel {
    /// Leaves the cached library time to appear and respond before any background reading starts.
    static let automaticRefreshDelay: Duration = .seconds(3)
    static let serverCheckInterval: Duration = .seconds(3600)

    /// Catches up with changes made while Macarok was closed, then keeps watching servers for new scans.
    /// Folder watchers already follow local changes while the app runs.
    func startAutomaticSourceRefresh() {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: Self.automaticRefreshDelay)
            var includeLocal = true
            while !Task.isCancelled {
                await self?.refreshSourcesAutomatically(includeLocal: includeLocal)
                includeLocal = false
                try? await Task.sleep(for: Self.serverCheckInterval)
            }
        }
    }

    func stopAutomaticSourceRefresh() { automaticRefreshTask?.cancel(); automaticRefreshTask = nil }

    /// Local folders are rescanned from their file cache, so only new or modified files are read.
    /// A server catalog is imported again only when its fingerprint changed or a previous import stopped early.
    func refreshSourcesAutomatically(includeLocal: Bool) async {
        guard store != nil, !isRefreshing, serverScan == nil else { return }
        var due = includeLocal ? sources.filter { $0.kind == .local } : []
        for source in sources where source.kind == .openSubsonic {
            guard !Task.isCancelled else { return }
            if await serverCatalogNeedsImport(source) { due.append(source) }
        }
        // A manual refresh started while servers were being checked takes precedence.
        guard !Task.isCancelled, !due.isEmpty, !isRefreshing, serverScan == nil else { return }
        startRefresh(sources: due.filter { sourcesByID[$0.id] != nil }, quiet: true)
    }

    func serverCatalogNeedsImport(_ source: SourceRecord) async -> Bool {
        let incompleteKey = Self.catalogImportKey(source.id), fingerprintKey = Self.serverFingerprintKey(source.id)
        guard let stored = try? await performLibraryWork({ store in
            (incomplete: try store.value(forKey: incompleteKey) != nil, fingerprint: try store.value(forKey: fingerprintKey))
        }) else { return false }
        if stored.incomplete { return true }
        guard let current = await remoteFingerprint(source) else { return false }
        return stored.fingerprint.flatMap { String(data: $0, encoding: .utf8) } != current
    }
}
