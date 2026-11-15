import AppKit
import SwiftUI

/// Adds queue undo after native text responders, without replacing the window's delegate or text undo manager.
struct QueueUndoHost: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> QueueUndoHostingView { QueueUndoHostingView(model: model) }
    func updateNSView(_ view: QueueUndoHostingView, context: Context) { view.attach() }
    static func dismantleNSView(_ view: QueueUndoHostingView, coordinator: ()) { view.detach() }
}

@MainActor
final class QueueUndoHostingView: NSView {
    private weak var model: AppModel?
    private weak var content: NSView?
    private let queueResponder: QueueUndoResponder
    private var resignation: NSObjectProtocol?
    init(model: AppModel) {
        self.model = model; queueResponder = QueueUndoResponder(model: model)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
    func attach() {
        guard let window, let contentView = window.contentView, content !== contentView else { return }
        detach()
        content = contentView
        queueResponder.nextResponder = contentView.nextResponder
        contentView.nextResponder = queueResponder
        window.titleVisibility = .hidden
        model?.mainPlayerWindow = window
        model?.queueUndoPresentation.refresh()
        resignation = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.resetArrowSeek() }
        }
    }
    func detach() {
        if let content, content.nextResponder === queueResponder { content.nextResponder = queueResponder.nextResponder }
        if let resignation { NotificationCenter.default.removeObserver(resignation) }
        resignation = nil; content = nil
        if model?.mainPlayerWindow === window { model?.mainPlayerWindow = nil; model?.resetArrowSeek(); model?.queueUndoPresentation.refresh() }
    }
}

@MainActor
private final class QueueUndoResponder: NSResponder, NSUserInterfaceValidations {
    weak var model: AppModel?
    init(model: AppModel) { self.model = model; super.init() }
    required init?(coder: NSCoder) { nil }
    @objc func undo(_ sender: Any?) { model?.queueUndoPresentation.undo() }
    @objc func redo(_ sender: Any?) { model?.queueUndoPresentation.redo() }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let presentation = model?.queueUndoPresentation else { return false }
        presentation.refresh()
        if item.action == #selector(undo(_:)) {
            (item as? NSMenuItem)?.title = presentation.undoTitle
            return presentation.canUndo
        }
        if item.action == #selector(redo(_:)) {
            (item as? NSMenuItem)?.title = presentation.redoTitle
            return presentation.canRedo
        }
        return false
    }
}
