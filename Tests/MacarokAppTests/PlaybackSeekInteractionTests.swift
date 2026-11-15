import Foundation
import XCTest
@testable import MacarokApp

final class PlaybackSeekInteractionTests: XCTestCase {
    func testTimelineClickKeepsTargetWhenSetterRunsBeforeEditingBegins() {
        let generation = UUID()
        var interaction = PlaybackSeekInteraction()

        interaction.change(to: 74.5, generation: generation)
        interaction.begin(at: 12, generation: generation)

        XCTAssertTrue(interaction.isEditing)
        XCTAssertEqual(interaction.position, 74.5, "The begin callback must not replace the clicked target with the old player position.")
        XCTAssertEqual(interaction.end(generation: generation), 74.5)
        XCTAssertFalse(interaction.isEditing)
        XCTAssertNil(interaction.position)
        XCTAssertNil(interaction.end(generation: generation), "A release can commit the gesture only once.")
    }

    func testDraggingAlsoWorksWhenEditingBeginsBeforeTheSetter() {
        let generation = UUID()
        var interaction = PlaybackSeekInteraction()

        interaction.begin(at: 12, generation: generation)
        interaction.change(to: 28, generation: generation)
        interaction.change(to: 42, generation: generation)

        XCTAssertEqual(interaction.position, 42)
        XCTAssertEqual(interaction.end(generation: generation), 42)
    }

    func testTouchingTheThumbWithoutChangingItsPositionDoesNotSeek() {
        let generation = UUID()
        var interaction = PlaybackSeekInteraction()
        interaction.begin(at: 12, generation: generation)
        XCTAssertEqual(interaction.position, 12)
        XCTAssertNil(interaction.end(generation: generation))
    }

    func testReleasingAnOldTrackGestureCannotSeekTheNewTrack() {
        let oldGeneration = UUID(), newGeneration = UUID()
        var interaction = PlaybackSeekInteraction()
        interaction.begin(at: 12, generation: oldGeneration)
        interaction.change(to: 74, generation: oldGeneration)

        XCTAssertNil(interaction.end(generation: newGeneration))
        XCTAssertFalse(interaction.isEditing)
        XCTAssertNil(interaction.position)
    }

    func testCancellationRejectsLateSettersAndReleaseEvenAfterRepeatedCancellation() {
        let oldGeneration = UUID(), newGeneration = UUID()
        var interaction = PlaybackSeekInteraction()
        interaction.begin(at: 12, generation: oldGeneration)
        interaction.change(to: 74, generation: oldGeneration)
        interaction.cancel()
        interaction.cancel()
        XCTAssertFalse(interaction.isEditing)
        XCTAssertNil(interaction.position)

        // SwiftUI can still deliver the interrupted drag's value with the new model generation.
        interaction.change(to: 80, generation: newGeneration)
        XCTAssertFalse(interaction.isEditing)
        XCTAssertNil(interaction.end(generation: newGeneration))

        interaction.begin(at: 2, generation: newGeneration)
        interaction.change(to: 18, generation: newGeneration)
        XCTAssertEqual(interaction.end(generation: newGeneration), 18)
    }

    func testAnActiveGestureCannotReplaceItsCapturedTrackGeneration() {
        let oldGeneration = UUID(), newGeneration = UUID()
        var interaction = PlaybackSeekInteraction()
        interaction.begin(at: 12, generation: oldGeneration)
        interaction.change(to: 74, generation: oldGeneration)
        interaction.change(to: 80, generation: newGeneration)
        XCTAssertFalse(interaction.isEditing)
        XCTAssertNil(interaction.end(generation: newGeneration))
    }

    func testNewTrackBeginDiscardsATargetCapturedForAnotherTrack() {
        let oldGeneration = UUID(), newGeneration = UUID()
        var interaction = PlaybackSeekInteraction()
        interaction.change(to: 74, generation: oldGeneration)
        interaction.begin(at: 3, generation: newGeneration)
        XCTAssertEqual(interaction.position, 3)
        XCTAssertNil(interaction.end(generation: newGeneration))
    }

    func testNewTimelineClickAfterCancellationStillSupportsSetterBeforeBegin() {
        let generation = UUID()
        var interaction = PlaybackSeekInteraction()
        interaction.begin(at: 12, generation: generation)
        interaction.change(to: 74, generation: generation)
        interaction.cancel()

        interaction.change(to: 36, generation: generation)
        interaction.begin(at: 15, generation: generation)
        XCTAssertTrue(interaction.isEditing)
        XCTAssertEqual(interaction.position, 36)
        XCTAssertEqual(interaction.end(generation: generation), 36)
    }
}
