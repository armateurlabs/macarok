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
        let choices: [(LibraryScope, String, NSImage?)] = [(.all, "All Sources", NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil))] + sources.map {
            (.source($0.id), $0.name, $0.kind.libraryImage)
        }
        context.coordinator.scopes = choices.map(\.0)
        button.removeAllItems()
        for (scope, title, image) in choices {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = image
            item.state = selection == scope ? .on : .off
            button.menu?.addItem(item)
        }
        if let index = choices.firstIndex(where: { $0.0 == selection }) { button.selectItem(at: index) }
        else { button.selectItem(at: 0) }
        button.isEnabled = !sources.isEmpty
        button.setAccessibilityValue(button.titleOfSelectedItem)
    }

    final class Coordinator: NSObject {
        var selection: Binding<LibraryScope?>
        var scopes: [LibraryScope] = []
        init(selection: Binding<LibraryScope?>) { self.selection = selection }
        @objc func selectSource(_ sender: NSPopUpButton) {
            guard scopes.indices.contains(sender.indexOfSelectedItem) else { return }
            selection.wrappedValue = scopes[sender.indexOfSelectedItem]
        }
    }
}

extension SourceKind {
    var libraryImage: NSImage? {
        self == .podcasts ? PodcastSourceIcon.image : NSImage(systemSymbolName: librarySymbol, accessibilityDescription: nil)
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
