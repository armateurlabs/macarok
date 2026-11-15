import AppKit
import Foundation
import MacarokCore
import XCTest
@testable import MacarokApp

@MainActor
final class QueueUndoMenuTests: XCTestCase {
    func testQueueMenuTitlesAndEnabledStateFollowUndoAndRedoNotifications() async throws {
        _ = NSApplication.shared
        let model = AppModel(registerSystemControls: false)
        let window = makeWindow()
        defer { window.close() }
        model.mainPlayerWindow = window
        let focus = MenuFocus(); focus.window = window
        let presentation = QueueUndoPresentation(model: model, keyWindow: { focus.window }, modalWindow: { focus.modal }, observeFocusEvents: false)
        XCTAssertFalse(presentation.canUndo)
        model.add([TrackRecord(id: "one", sourceID: "source", title: "One")])
        try await eventually { presentation.canUndo }
        XCTAssertEqual(presentation.undoTitle, "Undo Add to Playlist")
        presentation.undo()
        XCTAssertTrue(model.queue.isEmpty)
        XCTAssertFalse(presentation.canUndo)
        XCTAssertTrue(presentation.canRedo)
        XCTAssertEqual(presentation.redoTitle, "Redo Add to Playlist")
        presentation.redo()
        XCTAssertEqual(model.queue.count, 1)
        XCTAssertTrue(presentation.canUndo)
        XCTAssertFalse(presentation.canRedo)
    }

    func testTextEditorOwnsUndoEvenWhenItsWindowIsSettingsOrASheet() {
        _ = NSApplication.shared
        let model = AppModel(registerSystemControls: false)
        let main = makeWindow(), settings = makeWindow()
        defer { main.close(); settings.close() }
        model.mainPlayerWindow = main
        model.add([TrackRecord(id: "queue", sourceID: "source")])
        let original = model.queue
        let focus = MenuFocus(); focus.window = settings
        let presentation = QueueUndoPresentation(model: model, keyWindow: { focus.window }, modalWindow: { focus.modal }, observeFocusEvents: false)
        XCTAssertFalse(presentation.canUndo, "Settings must not expose queue undo merely because a queue edit exists.")
        let editor = MenuTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        settings.contentView?.addSubview(editor)
        XCTAssertTrue(settings.makeFirstResponder(editor))
        editor.seedTextUndo()
        focus.modal = settings
        presentation.refresh()
        XCTAssertTrue(presentation.canUndo)
        XCTAssertEqual(presentation.undoTitle, "Undo Typing")
        presentation.undo()
        XCTAssertEqual(editor.undoCalls, 1)
        XCTAssertEqual(model.queue, original)
        XCTAssertFalse(presentation.canUndo, "An empty text undo stack must never fall back to queue undo.")
    }

    func testActionsRecheckCurrentFocusInsteadOfUsingStaleEnabledState() {
        _ = NSApplication.shared
        let model = AppModel(registerSystemControls: false)
        let main = makeWindow(), other = makeWindow()
        defer { main.close(); other.close() }
        model.mainPlayerWindow = main
        model.add([TrackRecord(id: "queue", sourceID: "source")])
        let original = model.queue
        let focus = MenuFocus(); focus.window = main
        let presentation = QueueUndoPresentation(model: model, keyWindow: { focus.window }, modalWindow: { focus.modal }, observeFocusEvents: false)
        XCTAssertTrue(presentation.canUndo)
        focus.window = other
        presentation.undo()
        XCTAssertEqual(model.queue, original)
        XCTAssertFalse(presentation.canUndo)
        focus.window = main; focus.modal = other
        presentation.refresh()
        XCTAssertFalse(presentation.canUndo)
        presentation.undo()
        XCTAssertEqual(model.queue, original)
        focus.modal = nil
        presentation.refresh()
        XCTAssertTrue(presentation.canUndo)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        return window
    }
    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("The native undo presentation did not update."); throw URLError(.timedOut)
    }
}

@MainActor
private final class MenuFocus { var window: NSWindow?; var modal: NSWindow? }

@MainActor
private final class MenuTextView: NSTextView {
    let textUndo = UndoManager()
    private(set) var undoCalls = 0
    override var undoManager: UndoManager? { textUndo }
    func seedTextUndo() {
        textUndo.groupsByEvent = false
        textUndo.beginUndoGrouping()
        textUndo.registerUndo(withTarget: self) { target in MainActor.assumeIsolated { target.undoCalls += 1 } }
        textUndo.setActionName("Typing")
        textUndo.endUndoGrouping()
    }
}
