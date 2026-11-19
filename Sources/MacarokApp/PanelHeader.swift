import AppKit
import MacarokCore
import SwiftUI

struct PanelHeader<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9, content: content)
                .font(.system(size: 12))
                .buttonStyle(.borderless)
                .padding(.horizontal, 13)
                .frame(height: 42)
                .background(.bar)
            Divider()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// Empty, loading, and error states fill their panel on the same background as list and context content.
    func emptyPanel() -> some View { modifier(EmptyPanelLayout()) }
}

extension EnvironmentValues {
    /// The vertical middle of the main window's panels, in global coordinates, shared by every empty state.
    @Entry var emptyPanelCenterY: CGFloat?
}

/// Panels have headers of different heights; centering on one shared line keeps side-by-side empty states level.
private struct EmptyPanelLayout: ViewModifier {
    @Environment(\.emptyPanelCenterY) private var centerY

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let limit = frame.height * 0.3
            let shift = centerY.map { min(max($0 - frame.midY, -limit), limit) } ?? 0
            content.frame(width: proxy.size.width, height: proxy.size.height).offset(y: shift)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct SourceBadge: View {
    @Bindable var model: AppModel
    let sourceID: String
    var compact = false

    var body: some View {
        if model.isAllSources {
            Text(model.sourceName(for: sourceID))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, compact ? 0 : 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                .help("Source: \(model.sourceName(for: sourceID))")
        }
    }
}

struct SourceMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        NativeSourcePicker(selection: $model.libraryScope, sources: model.sources)
            .frame(maxWidth: .infinity).frame(height: 26)
            .accessibilityIdentifier("librarySourcePicker")
    }
}

/// NSPopUpButton preserves the platform's selected-item checkmark, source icon, and keyboard navigation.
struct NativeSourcePicker: NSViewRepresentable {
    @Binding var selection: LibraryScope?
    let sources: [SourceRecord]

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.bezelStyle = .rounded
        button.alignment = .left
        button.autoenablesItems = false
        (button.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectSource(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setAccessibilityLabel("Library source")
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        let choices = Self.choices(sources: sources)
        context.coordinator.scopes = choices.map { $0?.scope }
        button.removeAllItems()
        for choice in choices {
            guard let choice else { button.menu?.addItem(.separator()); continue }
            let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
            item.image = choice.image
            item.state = selection == choice.scope ? .on : .off
            button.menu?.addItem(item)
        }
        if let index = choices.firstIndex(where: { $0?.scope == selection }) { button.selectItem(at: index) }
        else { button.selectItem(at: 0) }
        button.isEnabled = !sources.isEmpty
        button.setAccessibilityValue(button.titleOfSelectedItem)
    }

    struct Choice { let scope: LibraryScope; let title: String; let image: NSImage? }

    /// All Sources, then music origins, then the built-in directories; nil marks a separator.
    /// Subscribed shows are reached through the single Podcasts entry.
    static func choices(sources: [SourceRecord]) -> [Choice?] {
        let all = Choice(scope: .all, title: "All Sources", image: NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil))
        let music = sources.filter { [.local, .openSubsonic].contains($0.kind) }.map { Choice(scope: .source($0.id), title: $0.name, image: $0.kind.libraryImage) }
        var directories = sources.filter { $0.kind == .radio }.map { Choice(scope: .source($0.id), title: $0.name, image: $0.kind.libraryImage) }
        if sources.contains(where: { $0.kind.isPodcast }) {
            directories.append(Choice(scope: .podcasts, title: "Podcasts", image: SourceKind.podcasts.libraryImage))
        }
        directories += sources.filter { $0.kind == .internetArchive }.map { Choice(scope: .source($0.id), title: $0.name, image: $0.kind.libraryImage) }
        var result: [Choice?] = [all]
        for group in [music, directories] where !group.isEmpty { result.append(nil); result += group }
        return result
    }

    final class Coordinator: NSObject {
        var selection: Binding<LibraryScope?>
        var scopes: [LibraryScope?] = []
        init(selection: Binding<LibraryScope?>) { self.selection = selection }
        @objc func selectSource(_ sender: NSPopUpButton) {
            guard scopes.indices.contains(sender.indexOfSelectedItem), let scope = scopes[sender.indexOfSelectedItem] else { return }
            selection.wrappedValue = scope
        }
    }
}

extension SourceKind {
    var libraryImage: NSImage? {
        isPodcast ? PodcastSourceIcon.image : NSImage(systemSymbolName: librarySymbol, accessibilityDescription: nil)
    }

    var librarySymbol: String {
        switch rawValue {
        case "local": "externaldrive"
        case "openSubsonic": "server.rack"
        case "radio": "antenna.radiowaves.left.and.right"
        case "internetArchive": "building.columns"
        default: "podcasts"
        }
    }
}

struct SourceGroupBadge: View {
    @Bindable var model: AppModel
    let sourceIDs: Set<String>

    var body: some View {
        if model.isAllSources, !sourceIDs.isEmpty {
            let names = sourceIDs.map { model.sourceName(for: $0) }.sorted()
            Text(names.count == 1 ? names[0] : "\(names.count) sources")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                .help(names.joined(separator: ", "))
                .accessibilityLabel("Sources: \(names.joined(separator: ", "))")
        }
    }
}
