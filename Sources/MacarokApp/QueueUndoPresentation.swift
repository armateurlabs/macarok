import AppKit
import Foundation
import Observation

/// Explicit Edit-menu state for SwiftUI, while each active text editor keeps its own undo history.
@MainActor @Observable
final class QueueUndoPresentation {
    private(set) var undoTitle = "Undo"
    private(set) var redoTitle = "Redo"
    private(set) var canUndo = false
    private(set) var canRedo = false
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let keyWindow: @MainActor () -> NSWindow?
    @ObservationIgnored private let modalWindow: @MainActor () -> NSWindow?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var focusMonitor: Any?
    @ObservationIgnored private var scheduled = false

    init(model: AppModel, keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow },
         modalWindow: @escaping @MainActor () -> NSWindow? = { NSApp.modalWindow }, observeFocusEvents: Bool = true) {
        self.model = model; self.keyWindow = keyWindow; self.modalWindow = modalWindow
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSText.didBeginEditingNotification, NSText.didEndEditingNotification, NSText.didChangeNotification,
            NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification,
            NSTextView.didChangeSelectionNotification, NSMenu.didBeginTrackingNotification
        ]
        for name in names {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        if observeFocusEvents {
            // Observe focus-changing events after AppKit handles them; never consume or reinterpret a key.
            focusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .keyUp]) { [weak self] event in
                self?.scheduleRefresh()
                return event
            }
        }
        refresh()
    }

    deinit {
        for observer in notifications { NotificationCenter.default.removeObserver(observer) }
        if let focusMonitor { MainActor.assumeIsolated { NSEvent.removeMonitor(focusMonitor) } }
    }

    private func scheduleRefresh() {
        guard !scheduled else { return }; scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false; self.refresh()
        }
    }

    private func targetManager() -> UndoManager? {
        guard let model, let window = keyWindow() else { return nil }
        if let editor = window.firstResponder as? NSTextView { return editor.undoManager }
        if PlaybackArrowKeys.webView(for: window.firstResponder) != nil {
            let manager = window.firstResponder?.undoManager
            return manager === model.queueUndoManager ? nil : manager
        }
        guard window === model.mainPlayerWindow, window.attachedSheet == nil, modalWindow() == nil else { return nil }
        return model.queueUndoManager
    }

    func refresh() {
        let manager = targetManager()
        let undoTitle = manager?.undoMenuItemTitle ?? "Undo"
        let redoTitle = manager?.redoMenuItemTitle ?? "Redo"
        let canUndo = manager?.canUndo ?? false
        let canRedo = manager?.canRedo ?? false
        if self.undoTitle != undoTitle { self.undoTitle = undoTitle }
        if self.redoTitle != redoTitle { self.redoTitle = redoTitle }
        if self.canUndo != canUndo { self.canUndo = canUndo }
        if self.canRedo != canRedo { self.canRedo = canRedo }
    }

    func undo() {
        if let manager = targetManager(), manager.canUndo { manager.undo() }
        refresh()
    }

    func redo() {
        if let manager = targetManager(), manager.canRedo { manager.redo() }
        refresh()
    }
}
