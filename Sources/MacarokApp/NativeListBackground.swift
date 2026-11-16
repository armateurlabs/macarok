import AppKit
import SwiftUI

/// Preserve native alternating rows and interaction, covering only the unused striped canvas.
struct NativeListBackground: NSViewRepresentable {
    let revision: Int
    /// Receives the backing table when it is found; receivers keep only a weak reference.
    var onTableChange: ((NSTableView?) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NativeListBackgroundProbe {
        context.coordinator.onTableChange = onTableChange
        let probe = NativeListBackgroundProbe(frame: .zero)
        probe.setAccessibilityElement(false)
        probe.setAccessibilityIdentifier("nativeListBackgroundProbe")
        probe.onLayout = { [weak coordinator = context.coordinator, weak probe] in
            guard let probe else { return }
            coordinator?.requestRefresh(from: probe)
        }
        return probe
    }

    func updateNSView(_ probe: NativeListBackgroundProbe, context: Context) {
        context.coordinator.onTableChange = onTableChange
        context.coordinator.requestRefresh(from: probe)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeListBackgroundProbe, context: Context) -> CGSize? {
        CGSize(width: max(0, proposal.width ?? 0), height: max(0, proposal.height ?? 0))
    }

    static func dismantleNSView(_ probe: NativeListBackgroundProbe, coordinator: Coordinator) {
        probe.onLayout = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private weak var table: NSTableView?
        var onTableChange: ((NSTableView?) -> Void)?
        private weak var probe: NSView?
        private var observers: [NSObjectProtocol] = []
        private var scheduled = false
        private var originalAlternation = false
        private var originalFrameNotifications = false
        private var originalBoundsNotifications = false
        private var originalRows: [ObjectIdentifier: RowBackground] = [:]
        private var emptyAreaMask: NativeListEmptyAreaMask?

        private struct RowBackground {
            weak var view: NSTableRowView?
            let postsFrameChanges: Bool
        }

        deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

        func requestRefresh(from probe: NSView? = nil) {
            if let probe { self.probe = probe }
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.refresh()
            }
        }

        func attach(to table: NSTableView) {
            guard self.table !== table else { return }
            let currentProbe = probe
            detach()
            probe = currentProbe
            self.table = table
            onTableChange?(table)
            originalAlternation = table.usesAlternatingRowBackgroundColors
            originalFrameNotifications = table.postsFrameChangedNotifications
            table.postsFrameChangedNotifications = true
            if let clip = table.enclosingScrollView?.contentView {
                originalBoundsNotifications = clip.postsBoundsChangedNotifications
                clip.postsBoundsChangedNotifications = true
                observe(NSView.boundsDidChangeNotification, object: clip)
                observe(NSView.frameDidChangeNotification, object: clip)
            }
            observe(NSView.frameDidChangeNotification, object: table)
            observe(NSTableView.columnDidResizeNotification, object: table)
            observe(NSTableView.selectionDidChangeNotification, object: table)
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let table = self.table, let row = notification.object as? NSTableRowView,
                          row.isDescendant(of: table) else { return }
                    self.requestRefresh()
                }
            })
            if let outline = table as? NSOutlineView {
                observe(NSOutlineView.itemDidExpandNotification, object: outline)
                observe(NSOutlineView.itemDidCollapseNotification, object: outline)
            }
        }

        func detach() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            emptyAreaMask?.removeFromSuperview()
            emptyAreaMask = nil
            if let table {
                table.postsFrameChangedNotifications = originalFrameNotifications
                table.enclosingScrollView?.contentView.postsBoundsChangedNotifications = originalBoundsNotifications
                for original in originalRows.values {
                    if let row = original.view, row.isDescendant(of: table) {
                        row.postsFrameChangedNotifications = original.postsFrameChanges
                    }
                }
                table.usesAlternatingRowBackgroundColors = originalAlternation
            }
            originalRows.removeAll()
            table = nil
            probe = nil
        }

        /// Also used by offscreen native-table tests; no delegate, selection, or row models are replaced.
        func refresh() {
            if let probe {
                if table?.superview == nil || table?.window !== probe.window {
                    if let found = Self.findTable(for: probe) { attach(to: found) }
                    else { detach(); return }
                }
            }
            guard let table else { return }
            table.layoutSubtreeIfNeeded()
            // SwiftUI owns row backgrounds and can reapply them after each List update. Keeping
            // its native painter avoids fighting that lifecycle or changing selection styling.
            if !table.usesAlternatingRowBackgroundColors { table.usesAlternatingRowBackgroundColors = true }
            if let scroll = table.enclosingScrollView {
                let mask: NativeListEmptyAreaMask
                if let existing = emptyAreaMask, existing.superview === scroll { mask = existing }
                else {
                    emptyAreaMask?.removeFromSuperview()
                    mask = NativeListEmptyAreaMask(frame: scroll.contentView.frame)
                    mask.table = table
                    mask.autoresizingMask = [.width, .height]
                    mask.setAccessibilityElement(false)
                    scroll.addSubview(mask, positioned: .above, relativeTo: scroll.contentView)
                    emptyAreaMask = mask
                }
                mask.appearance = table.effectiveAppearance
                mask.frame = scroll.contentView.frame
                mask.needsDisplay = true
            }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound, visible.length > 0 else { return }
            for index in visible.location..<min(NSMaxRange(visible), table.numberOfRows) {
                guard let row = table.rowView(atRow: index, makeIfNecessary: false) else { continue }
                let key = ObjectIdentifier(row)
                if originalRows[key] == nil {
                    originalRows[key] = RowBackground(view: row, postsFrameChanges: row.postsFrameChangedNotifications)
                    row.postsFrameChangedNotifications = true
                }
            }
            if originalRows.count > 300 { originalRows = originalRows.filter { $0.value.view != nil } }
        }

        private func observe(_ name: Notification.Name, object: AnyObject) {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestRefresh() }
            })
        }

        private static func findTable(for probe: NSView) -> NSTableView? {
            var ancestor = probe.superview
            while let container = ancestor {
                let rect = probe.convert(probe.bounds, to: container)
                let candidates = tables(in: container).compactMap { table -> (NSTableView, CGFloat)? in
                    let viewport: NSView = table.enclosingScrollView ?? table
                    let frame = viewport.convert(viewport.bounds, to: container)
                    let intersection = rect.intersection(frame)
                    guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return nil }
                    return (table, intersection.width * intersection.height)
                }
                if let best = candidates.max(by: { $0.1 < $1.1 }) { return best.0 }
                ancestor = container.superview
            }
            return nil
        }

        private static func tables(in view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap { tables(in: $0) }
        }
    }
}

/// Transparent, non-accessible layout observation leaves mouse, keyboard, drag, and menus with List.
final class NativeListBackgroundProbe: NSView {
    var onLayout: (() -> Void)?
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); onLayout?() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onLayout?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); onLayout?() }
    override func layout() { super.layout(); onLayout?() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); onLayout?() }
}

/// The full-size view remains transparent over real rows. Its draw-time geometry also handles a
/// native row insertion that lands after SwiftUI's representable update in the same run-loop turn.
final class NativeListEmptyAreaMask: NSView {
    weak var table: NSTableView?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var emptyArea: NSRect {
        guard let table, let viewport = table.enclosingScrollView?.contentView else { return .zero }
        let visible = convert(viewport.bounds, from: viewport).intersection(bounds)
        guard !visible.isNull else { return .zero }
        let end = table.numberOfRows > 0 ? convert(table.rect(ofRow: table.numberOfRows - 1), from: table).maxY : visible.minY
        let start = max(visible.minY, end)
        return NSRect(x: visible.minX, y: start, width: visible.width, height: max(0, visible.maxY - start))
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = emptyArea.intersection(dirtyRect)
        guard fill.width > 0, fill.height > 0 else { return }
        let background = table?.backgroundColor ?? .textBackgroundColor
        // SwiftUI can make the table itself transparent; covering its canvas needs an opaque fill.
        if background.alphaComponent >= 1 { background.setFill() }
        else { NSColor.textBackgroundColor.setFill() }
        fill.fill()
    }
}
