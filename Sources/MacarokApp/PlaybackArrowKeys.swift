import AppKit
import Foundation

/// Uses the OS repeat events; a held key accumulates from the last requested seek, not a stale VLC sample.
struct PlaybackArrowKeys {
    private var keyCode: UInt16?
    private var generation: UUID?
    private var requestedPosition: Double?

    static func isReserved(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        [123, 124].contains(keyCode) && modifiers.intersection([.command, .option, .control, .shift]).isEmpty
    }

    mutating func reset() { keyCode = nil; generation = nil; requestedPosition = nil }

    mutating func target(keyCode: UInt16, isRepeat: Bool, generation: UUID, position: Double, duration: Double) -> Double? {
        if isRepeat && (self.keyCode != keyCode || self.generation != generation) { return nil }
        let base = isRepeat && self.keyCode == keyCode && self.generation == generation ? requestedPosition ?? position : position
        let target = max(0, duration > 0 ? min(duration, base + (keyCode == 123 ? -5 : 5)) : base + (keyCode == 123 ? -5 : 5))
        self.keyCode = keyCode; self.generation = generation; requestedPosition = target
        return target
    }

    @MainActor static func accepts(window: NSWindow?, mainWindow: NSWindow?) -> Bool {
        guard let window, window === mainWindow, window.isKeyWindow,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        var responder = window.firstResponder
        while let current = responder, current !== window {
            if current is NSTextView || current is NSControl || current is NSTableView || current is NSOutlineView || current is NSCollectionView { return false }
            responder = current.nextResponder
        }
        return true
    }
}
