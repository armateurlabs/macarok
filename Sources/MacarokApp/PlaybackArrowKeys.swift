import AppKit
import Foundation
import WebKit

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

    /// Text, library outlines, and other controls keep native arrows. The timeline and the active
    /// playlist (vertical-only navigation) use them for the model's fixed seek step.
    @MainActor static func accepts(window: NSWindow?, mainWindow: NSWindow?, activePlaylist: NSTableView? = nil) -> Bool {
        guard let window, window === mainWindow, window.isKeyWindow,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        guard webView(for: window.firstResponder) == nil else { return false }
        return respondersAllowSeek(from: window.firstResponder, until: window, activePlaylist: activePlaylist)
    }

    @MainActor static func respondersAllowSeek(from firstResponder: NSResponder?, until window: NSWindow?,
                                               activePlaylist: NSTableView?) -> Bool {
        var responder = firstResponder
        while let current = responder, current !== window {
            if current is TimelineSlider { return true }
            if let activePlaylist, current === activePlaylist { return true }
            if current is NSTextView || current is NSControl || current is NSTableView || current is NSOutlineView || current is NSCollectionView { return false }
            responder = current.nextResponder
        }
        return true
    }

    @MainActor static func webView(for responder: NSResponder?) -> WKWebView? {
        var responder = responder
        while let current = responder {
            if let webView = current as? WKWebView { return webView }
            if let view = current as? NSView {
                var parent = view.superview
                while let ancestor = parent {
                    if let webView = ancestor as? WKWebView { return webView }
                    parent = ancestor.superview
                }
            }
            responder = current.nextResponder
        }
        return nil
    }
}
