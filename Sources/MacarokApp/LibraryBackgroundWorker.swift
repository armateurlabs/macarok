import AppKit
import Foundation
import MacarokCore

/// Serializes database writes away from the UI and rejects obsolete catalog operations.
actor LibraryBackgroundWorker {
    private var refreshGenerations: [String: UUID] = [:]
    private var savedQueueContentRevision = 0
    private var queueCheckpoint: (revision: Int, index: Int, position: Double)?

    func perform<Value: Sendable>(store: LibraryStore,
                                 _ operation: @Sendable (LibraryStore) throws -> Value) throws -> Value {
        try Task.checkCancellation()
        return try operation(store)
    }

    func beginRefresh(store: LibraryStore, sourceID: String, generation: UUID, incompleteKey: String?) throws {
        try Task.checkCancellation()
        guard try store.sources().contains(where: { $0.id == sourceID }) else { throw CancellationError() }
        refreshGenerations[sourceID] = generation
        if let incompleteKey { try store.setValue(Data([1]), forKey: incompleteKey) }
    }

    @discardableResult
    func upsert(store: LibraryStore, sourceID: String, generation: UUID, tracks: [TrackRecord]) throws -> Bool {
        try requireCurrent(sourceID: sourceID, generation: generation)
        return try store.upsertTracks(tracks)
    }

    @discardableResult
    func replace(store: LibraryStore, sourceID: String, generation: UUID, tracks: [TrackRecord],
                 coverage: LocalScanCoverage = .all, rootURL: URL? = nil) throws -> Bool {
        try requireCurrent(sourceID: sourceID, generation: generation)
        return try store.replaceSourceTracks(sourceID: sourceID, with: tracks, coverage: coverage, rootURL: rootURL)
    }

    func saveScanCache(store: LibraryStore, sourceID: String, generation: UUID,
                       entries: [LocalScanFileCacheEntry], isComplete: Bool,
                       coverage: LocalScanCoverage = .all, rootURL: URL? = nil) throws {
        try requireCurrent(sourceID: sourceID, generation: generation)
        try store.saveLocalScanCache(sourceID: sourceID, entries: entries, isComplete: isComplete, coverage: coverage, rootURL: rootURL)
    }

    func updateRadioStation(store: LibraryStore, station: RadioStationRecord, generation: UUID) throws {
        try requireCurrent(sourceID: station.sourceID, generation: generation)
        guard try store.sources().contains(where: { $0.id == station.sourceID && $0.kind == .radio }) else { throw CancellationError() }
        try store.saveRadioStation(station, favorite: true)
    }

    @discardableResult
    func finishCatalog(store: LibraryStore, sourceID: String, generation: UUID,
                       activeIDs: Set<String>, incompleteKey: String) throws -> Bool {
        try requireCurrent(sourceID: sourceID, generation: generation)
        let changed = try store.reconcileTracks(sourceID: sourceID, activeIDs: activeIDs)
        try store.setValue(nil, forKey: incompleteKey)
        return changed
    }

    func invalidateRefresh(sourceID: String, generation: UUID) {
        if refreshGenerations[sourceID] == generation { refreshGenerations[sourceID] = nil }
    }

    func deleteSource(store: LibraryStore, sourceID: String, incompleteKey: String) throws {
        refreshGenerations[sourceID] = nil
        try store.deleteSource(id: sourceID)
        try store.setValue(nil, forKey: incompleteKey)
    }

    func saveQueue(store: LibraryStore, trackIDs: [String], currentIndex: Int,
                   position: Double, revision: Int) throws {
        guard revision > savedQueueContentRevision else { return }
        let newerCheckpoint = queueCheckpoint.flatMap { $0.revision > revision ? $0 : nil }
        try store.saveQueue(trackIDs: trackIDs, currentIndex: newerCheckpoint?.index ?? currentIndex,
                            position: newerCheckpoint?.position ?? position)
        savedQueueContentRevision = revision
        if newerCheckpoint == nil { queueCheckpoint = nil }
    }

    func saveQueuePosition(store: LibraryStore, currentIndex: Int, position: Double, revision: Int) throws {
        guard revision > savedQueueContentRevision, revision > queueCheckpoint?.revision ?? 0 else { return }
        try store.saveQueuePosition(currentIndex: currentIndex, position: position)
        queueCheckpoint = (revision, currentIndex, position)
    }

    func cacheArtwork(_ data: Data, key: String, directory: URL) throws -> URL {
        guard NSImage(data: data) != nil else { throw AppFailure.invalidArtwork }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(key + ".image")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func requireCurrent(sourceID: String, generation: UUID) throws {
        try Task.checkCancellation()
        guard refreshGenerations[sourceID] == generation else { throw CancellationError() }
    }
}
