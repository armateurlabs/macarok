import AppKit
import Foundation

struct QueueEditState {
    let items: [QueueItem]
    let currentID: UUID?
    let selectionIDs: Set<UUID>
    let resumePosition: Double
}

@MainActor
final class QueueUndoController {
    let manager = UndoManager()
    private let target = QueueUndoTarget()

    init() { manager.groupsByEvent = false; manager.levelsOfUndo = 100 }

    func register(model: AppModel, state: QueueEditState, name: String) {
        target.model = model
        let isReplay = manager.isUndoing || manager.isRedoing
        if !isReplay { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: target) { target in
            MainActor.assumeIsolated { target.model?.restoreQueueEdit(state, name: name) }
        }
        manager.setActionName(name)
        if !isReplay { manager.endUndoGrouping() }
    }
}

@MainActor
private final class QueueUndoTarget { weak var model: AppModel? }
