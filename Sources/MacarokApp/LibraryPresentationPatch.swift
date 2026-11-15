import Foundation
import MacarokCore

enum LibraryPatchKind { case history, rating, artwork }

/// Only touched presentation fields overlay a snapshot built before their database commit.
struct LibraryPresentationPatch: Sendable {
    var revision: Int
    var history: (count: Int, date: Date?)?
    var rating: Int?
    var artwork: (path: String?, locked: Bool)?

    mutating func merge(_ track: TrackRecord, kind: LibraryPatchKind, revision: Int) {
        self.revision = revision
        switch kind {
        case .history: history = (track.playCount, track.lastPlayedAt)
        case .rating: rating = track.rating
        case .artwork: artwork = (track.artworkPath, track.metadataLocked)
        }
    }
    func applying(to original: TrackRecord) -> TrackRecord {
        var value = original
        if let history { value.playCount = history.count; value.lastPlayedAt = history.date }
        if let rating { value.rating = rating }
        if let artwork { value.artworkPath = artwork.path; value.metadataLocked = artwork.locked }
        return value
    }
}

actor AsyncOperationGate {
    private var available: Int
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    init(limit: Int) { available = max(1, limit) }
    func withPermit<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
    private func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 { available -= 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func release() {
        if !waiters.isEmpty { waiters.removeFirst().1.resume() }
        else { available += 1 }
    }
}
