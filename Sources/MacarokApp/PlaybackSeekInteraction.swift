import Foundation

/// Retains a slider's requested position independently of SwiftUI callback ordering and player updates.
struct PlaybackSeekInteraction {
    private(set) var isEditing = false
    private(set) var position: Double?
    private var generation: UUID?
    private var hasChange = false
    private var waitsForNewBegin = false

    mutating func change(to position: Double, generation: UUID) {
        guard position.isFinite else { return }
        if isEditing, self.generation != generation { cancel() }
        self.position = position
        self.generation = generation
        hasChange = true
        if !waitsForNewBegin { isEditing = true }
    }

    mutating func begin(at currentPosition: Double, generation: UUID) {
        if !hasChange || self.generation != generation {
            position = currentPosition.isFinite ? currentPosition : 0
            hasChange = false
        }
        self.generation = generation
        waitsForNewBegin = false
        isEditing = true
    }

    mutating func end(generation: UUID) -> Double? {
        let target = hasChange && self.generation == generation && !waitsForNewBegin ? position : nil
        self = Self()
        return target
    }

    mutating func cancel() {
        let wasActive = waitsForNewBegin || isEditing || hasChange
        self = Self()
        // A late setter/release from the interrupted drag cannot seek a replacement queue entry.
        waitsForNewBegin = wasActive
    }
}
