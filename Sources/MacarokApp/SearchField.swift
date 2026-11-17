import SwiftUI

/// A rounded search field with a magnifier and a clear button, like the native macOS search field.
/// Escape also clears it. `onClear` lets fields that search on submit reset their results too.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}
    var onClear: () -> Void = {}

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).focused(focus).onSubmit(onSubmit)
                .onExitCommand { clear() }
            if !text.isEmpty {
                Button(action: clear) { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 12)).padding(.horizontal, 7).frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focus.wrappedValue ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor),
                                                               lineWidth: focus.wrappedValue ? 2 : 0.5))
        .contentShape(Rectangle()).onTapGesture { focus.wrappedValue = true }
    }

    private func clear() {
        guard !text.isEmpty else { return }
        text = ""; onClear()
    }
}

/// Opens the list area: a divider ends the filters, and the heading sits on the list's background
/// with its item count and sort direction, so it reads as part of the content.
struct LibraryListHeader: View {
    @Bindable var model: AppModel
    let title: String
    var count: Int?
    var sortEnabled = true

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                if let count { Text(count.formatted()).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
                if model.isSearching { ProgressView().controlSize(.mini) }
                Spacer(minLength: 4)
                Button(action: model.toggleLibrarySort) {
                    HStack(spacing: 3) {
                        Image(systemName: model.librarySortIsDescending ? "chevron.down" : "chevron.up").font(.system(size: 9, weight: .semibold))
                        Text(model.librarySortLabel)
                    }.font(.system(size: 10)).foregroundStyle(.secondary).frame(minHeight: 18).contentShape(Rectangle())
                }.buttonStyle(.borderless).help(model.librarySortHelp).accessibilityLabel(model.librarySortHelp)
                    .accessibilityIdentifier("librarySortDirection").disabled(!sortEnabled)
            }.padding(.horizontal, 14).frame(height: 26).frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            Divider().opacity(0.5)
        }
    }
}

/// The library views as one grouped control: the selected view is raised like a segmented control.
struct LibraryViewPicker: View {
    @Bindable var model: AppModel

    var body: some View {
        let views = model.visibleLibraryViews
        // Seven views balance as 4 + 3 instead of leaving one alone on a third row.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: views.count > 6 ? 4 : 3), spacing: 2) {
            ForEach(views) { view in
                let selected = model.libraryView == view
                Button { model.selectLibraryView(view) } label: {
                    Text(view.title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : .secondary)
                        .frame(maxWidth: .infinity).frame(height: 22)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.padding(2).background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
    }
}

extension AppModel {
    private var sortsByDate: Bool { [.years, .podcasts].contains(currentSortKey) }
    var librarySortLabel: String { sortsByDate ? (librarySortIsDescending ? "Newest" : "Oldest") : (librarySortIsDescending ? "Z–A" : "A–Z") }
    var librarySortHelp: String {
        let order = sortsByDate ? (librarySortIsDescending ? "newest first" : "oldest first") : (librarySortIsDescending ? "Z to A" : "A to Z")
        return "Sorted \(order). Click to reverse."
    }
}
