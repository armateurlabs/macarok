import AppKit
import SwiftUI

/// How a list shows its selection. Neither style paints the native accent band, so selected labels keep
/// their colors; selection itself, keyboard navigation, and accessibility stay native.
enum NativeListSelectionStyle {
    /// A soft accent tint inside each selected row, merged across adjacent selected rows.
    case soft
    /// The list draws its own selection backgrounds, such as the playlist's album blocks.
    case custom
}

/// The app's selection tints. Buttons, controls, and menus keep the system accent.
enum SoftSelectionPalette {
    static let radius: CGFloat = 7
    /// Aligns with the inset list's native row stripes, whose corner radius is also 7 points.
    static let inset: CGFloat = 10

    /// Strong marks a selected row or album header band; soft marks a selected album's body.
    /// The tint turns neutral while the window is inactive.
    static func tint(strong: Bool, active: Bool, dark: Bool) -> NSColor {
        guard active else {
            return (dark ? NSColor.white : NSColor.black).withAlphaComponent(strong ? (dark ? 0.12 : 0.08) : (dark ? 0.06 : 0.04))
        }
        return NSColor.controlAccentColor.withAlphaComponent(strong ? (dark ? 0.24 : 0.16) : (dark ? 0.11 : 0.07))
    }

    /// An opaque base under the tint hides the native row stripes, whose own rounded corners would notch a block.
    static let base = NSColor.textBackgroundColor

    /// Rounded only where a selection block starts or ends, in a flipped coordinate space.
    static func path(in rect: NSRect, roundsTop: Bool, roundsBottom: Bool) -> NSBezierPath {
        let limit = min(radius, rect.width / 2, rect.height / 2)
        let top = roundsTop ? limit : 0, bottom = roundsBottom ? limit : 0
        let path = NSBezierPath()
        func corner(_ point: NSPoint, _ next: NSPoint, _ radius: CGFloat) {
            if radius > 0 { path.appendArc(from: point, to: next, radius: radius) } else { path.line(to: point) }
        }
        path.move(to: NSPoint(x: rect.midX, y: rect.minY))
        corner(NSPoint(x: rect.maxX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.maxY), top)
        corner(NSPoint(x: rect.maxX, y: rect.maxY), NSPoint(x: rect.minX, y: rect.maxY), bottom)
        corner(NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.minX, y: rect.minY), bottom)
        corner(NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.midX, y: rect.minY), top)
        path.close()
        return path
    }
}

/// Preserve native alternating rows and interaction, covering only the unused striped canvas.
struct NativeListBackground: NSViewRepresentable {
    let revision: Int
    var selectionStyle: NativeListSelectionStyle = .soft
    /// Receives the backing table when it is found; receivers keep only a weak reference.
    var onTableChange: ((NSTableView?) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NativeListBackgroundProbe {
        context.coordinator.onTableChange = onTableChange
        context.coordinator.selectionStyle = selectionStyle
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
        context.coordinator.selectionStyle = selectionStyle
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
        var selectionStyle: NativeListSelectionStyle = .soft
        private weak var probe: NSView?
        private var observers: [NSObjectProtocol] = []
        private var scheduled = false
        private var originalAlternation = false
        private var originalHighlightStyle: NSTableView.SelectionHighlightStyle?
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
            originalHighlightStyle = table.selectionHighlightStyle
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
            observe(NSTableView.selectionIsChangingNotification, object: table)
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let window = notification.object as? NSWindow, window === self.table?.window else { return }
                        self.requestRefresh()
                    }
                })
            }
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
                        row.subviews.filter { $0 is NativeListSelectionView }.forEach { $0.removeFromSuperview() }
                    }
                }
                table.usesAlternatingRowBackgroundColors = originalAlternation
                if let originalHighlightStyle { table.selectionHighlightStyle = originalHighlightStyle }
            }
            originalHighlightStyle = nil
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
            // SwiftUI may restore the native highlight when it updates the table.
            if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
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
                let painter = row.subviews.lazy.compactMap { $0 as? NativeListSelectionView }.first
                switch selectionStyle {
                case .soft:
                    let view = painter ?? NativeListSelectionView(frame: row.bounds)
                    if painter == nil {
                        view.autoresizingMask = [.width, .height]
                        view.setAccessibilityElement(false)
                        // Above the row's own stripe and below its content, where the native band would be.
                        row.addSubview(view, positioned: .below, relativeTo: nil)
                    }
                    view.table = table
                    view.needsDisplay = true
                case .custom:
                    painter?.removeFromSuperview()
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

/// Paints a selected row in place of the hidden native band. It reads the selection from the table, so
/// a reused row view never shows a stale state, and rounds only the ends of a run of selected rows.
class NativeListSelectionView: NSView {
    weak var table: NSTableView?
    private var rowObservations: [NSKeyValueObservation] = []
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        rowObservations = []
        guard let row = superview as? NSTableRowView else { return }
        // The table sets these synchronously with a click, so the tint is drawn in the click's own frame,
        // before SwiftUI rebuilds the panels that react to the new selection.
        let redraw: (NSTableRowView, NSKeyValueObservedChange<Bool>) -> Void = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        rowObservations = [row.observe(\.isSelected, changeHandler: redraw),
                           row.observe(\.isPreviousRowSelected, changeHandler: redraw),
                           row.observe(\.isNextRowSelected, changeHandler: redraw)]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let table, let rowView = superview as? NSTableRowView else { return }
        let row = table.row(for: rowView)
        guard row >= 0, table.isRowSelected(row) else { return }
        let path = SoftSelectionPalette.path(in: bounds.insetBy(dx: SoftSelectionPalette.inset, dy: 0),
                                             roundsTop: row == 0 || !table.isRowSelected(row - 1),
                                             roundsBottom: row + 1 >= table.numberOfRows || !table.isRowSelected(row + 1))
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        SoftSelectionPalette.base.setFill(); path.fill()
        SoftSelectionPalette.tint(strong: true, active: window?.isKeyWindow ?? false, dark: dark).setFill(); path.fill()
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
