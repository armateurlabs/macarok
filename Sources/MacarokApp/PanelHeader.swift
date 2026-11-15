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

    var body: some View {
        if model.isAllSources {
            Text(model.sourceName(for: sourceID))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                .help("Source: \(model.sourceName(for: sourceID))")
        }
    }
}

struct SourceMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            Picker("Library source", selection: $model.libraryScope) {
                Label("All Sources", systemImage: "square.stack.3d.up").tag(Optional(LibraryScope.all))
                ForEach(model.sources) { source in
                    Label(source.name, systemImage: source.kind == .local ? "externaldrive" : source.kind == .openSubsonic ? "server.rack" : "podcasts")
                        .tag(Optional(LibraryScope.source(source.id)))
                }
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            Text(model.scopeTitle).fontWeight(.semibold).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .menuIndicator(.visible)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .disabled(model.sources.isEmpty)
        .accessibilityLabel("Library source")
        .accessibilityValue(model.scopeTitle)
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
