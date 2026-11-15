import AppKit
import Foundation
import MacarokCore

/// Serializes database writes away from the UI and rejects obsolete catalog operations.
actor LibraryBackgroundWorker {
    private var refreshGenerations: [String: UUID] = [:]
    private var savedQueueRevision = 0

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

    func upsert(store: LibraryStore, sourceID: String, generation: UUID, tracks: [TrackRecord]) throws {
        try requireCurrent(sourceID: sourceID, generation: generation)
        try store.upsertTracks(tracks)
    }

    func replace(store: LibraryStore, sourceID: String, generation: UUID, tracks: [TrackRecord]) throws {
        try requireCurrent(sourceID: sourceID, generation: generation)
        try store.replaceSourceTracks(sourceID: sourceID, with: tracks)
    }

    func finishCatalog(store: LibraryStore, sourceID: String, generation: UUID,
                       activeIDs: Set<String>, incompleteKey: String) throws {
        try requireCurrent(sourceID: sourceID, generation: generation)
        try store.reconcileTracks(sourceID: sourceID, activeIDs: activeIDs)
        try store.setValue(nil, forKey: incompleteKey)
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
        guard revision > savedQueueRevision else { return }
        try store.saveQueue(trackIDs: trackIDs, currentIndex: currentIndex, position: position)
        savedQueueRevision = revision
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
