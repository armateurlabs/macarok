import Foundation

/// Interpolates only toward received playback positions. A missing sample can never make this
/// clock advance beyond the last measurement, and it never supplies timing to the audio engine.
struct PlaybackTimelineSmoothing {
    private(set) var target: Double = 0
    private var origin: Double = 0
    private var startedAt: TimeInterval = 0
    private var duration: TimeInterval = 0
    private var lastMeasurementAt: TimeInterval?
    private var generation: UUID?
    private var seekRevision: UInt64 = 0

    mutating func update(to position: Double, at time: TimeInterval, playing: Bool,
                         generation: UUID?, seekRevision: UInt64) -> Double {
        guard position.isFinite, time.isFinite else { return value(at: time) }
        let displayed = value(at: time)
        let sameOccurrence = self.generation == generation && self.seekRevision == seekRevision
        self.generation = generation; self.seekRevision = seekRevision
        guard playing, sameOccurrence, let previousTime = lastMeasurementAt,
              time >= previousTime, time - previousTime <= 0.75,
              position >= target, position - target < 1 else {
            snap(to: position, at: time)
            return position
        }
        // SwiftUI can update buffering, appearance, and duration without receiving a new clock
        // position. Repeating a value must not restart an unfinished transition or extend a stall.
        guard position != target else { return displayed }
        origin = min(displayed, position)
        target = position
        startedAt = time
        duration = min(0.2, time - previousTime)
        lastMeasurementAt = time
        return value(at: time)
    }

    func value(at time: TimeInterval) -> Double {
        guard duration > 0, time.isFinite else { return target }
        let fraction = min(1, max(0, (time - startedAt) / duration))
        return min(target, origin + (target - origin) * fraction)
    }

    func isAnimating(at time: TimeInterval) -> Bool {
        duration > 0 && time < startedAt + duration && origin != target
    }

    private mutating func snap(to position: Double, at time: TimeInterval) {
        target = position; origin = position; startedAt = time; duration = 0; lastMeasurementAt = time
    }
}
