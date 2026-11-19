import AppKit
import SwiftUI

/// Two stable header rows keep navigation centered independently of the displayed content.
struct CenterPanelHeader: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader {
                CenterSegmentedPicker(selection: Binding(get: { model.centerPage == .home ? 0 : 1 }, set: {
                    model.selectCenterPage($0 == 0 ? .home : .playing)
                }), labels: ["Home", "Playing"], label: "Center panel", identifier: "centerPagePicker", maximumWidth: 208)
                .frame(width: 208).frame(maxWidth: .infinity)
            }.accessibilityIdentifier("contextPanelHeader")

            PanelHeader {
                Group {
                    // A show's Home has no recent/most-played sections; the row stays for a stable layout.
                    if model.centerPage == .home && (model.focusedPodcastShowID != nil || model.libraryScope == .podcasts) {
                        Color.clear
                    } else if model.centerPage == .playing && (model.isPodcastTrack(model.playingContextTrack) || model.isRadioTrack(model.playingContextTrack)) {
                        Color.clear
                    } else if model.centerPage == .home {
                        CenterSegmentedPicker(selection: Binding(get: { HomeFilter.allCases.firstIndex(of: model.homeFilter) ?? 0 }, set: {
                            guard HomeFilter.allCases.indices.contains($0) else { return }
                            model.selectHomeFilter(HomeFilter.allCases[$0])
                        }), labels: HomeFilter.allCases.map(\.title), label: "Home filter", identifier: "homeFilterPicker",
                                              maximumWidth: 522, fontSize: 11, proportional: true)
                            .frame(maxWidth: 522)
                    } else {
                        CenterSegmentedPicker(selection: Binding(get: { ContextMode.allCases.firstIndex(of: model.contextMode) ?? 0 }, set: {
                            guard ContextMode.allCases.indices.contains($0) else { return }
                            model.selectContextMode(ContextMode.allCases[$0])
                        }), labels: ContextMode.allCases.map(\.title), label: "Playing view", identifier: "playingViewPicker", maximumWidth: 522,
                                              fontSize: 10.5, proportional: true,
                                              compactLabels: ContextMode.allCases.map { mode in
                                                  switch mode {
                                                  case .editMetadata: "Song metadata"
                                                  case .editAlbumMetadata: "Album metadata"
                                                  default: mode.title
                                                  }
                                              })
                            .frame(maxWidth: 522)
                    }
                }.frame(maxWidth: .infinity)
            }.accessibilityIdentifier("contextPanelSubheader")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// AppKit can shrink its labels proportionally without SwiftUI's segmented picker's intrinsic-width overflow.
private struct CenterSegmentedPicker: NSViewRepresentable {
    @Binding var selection: Int
    let labels: [String]
    let label: String
    let identifier: String
    let maximumWidth: CGFloat
    var fontSize: CGFloat = 12
    var proportional = false
    var compactLabels: [String]?

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> CenterSegmentedControl {
        let control = CenterSegmentedControl(frame: .zero)
        control.segmentStyle = .rounded
        control.trackingMode = .selectOne
        control.controlSize = .regular
        control.target = context.coordinator
        control.action = #selector(Coordinator.select(_:))
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: CenterSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.segmentDistribution = proportional ? .fillProportionally : .fillEqually
        control.configure(fullLabels: labels, compactLabels: compactLabels, fontSize: fontSize)
        control.selectedSegment = labels.indices.contains(selection) ? selection : -1
        control.setAccessibilityLabel(label)
        control.setAccessibilityHelp(labels.joined(separator: ", "))
        control.setAccessibilityIdentifier(identifier)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CenterSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: min(maximumWidth, max(0, proposal.width ?? maximumWidth)), height: 24)
    }

    final class Coordinator: NSObject {
        var selection: Binding<Int>
        init(selection: Binding<Int>) { self.selection = selection }
        @objc func select(_ sender: NSSegmentedControl) {
            guard sender.selectedSegment >= 0 else { return }
            selection.wrappedValue = sender.selectedSegment
        }
    }
}

private final class CenterSegmentedControl: NSSegmentedControl {
    private var fullLabels: [String] = []
    private var compactLabels: [String]?
    private var displayedLabels: [String] = []
    private var preferredFontSize: CGFloat = 12

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }

    func configure(fullLabels: [String], compactLabels: [String]?, fontSize: CGFloat) {
        self.fullLabels = fullLabels
        self.compactLabels = compactLabels?.count == fullLabels.count ? compactLabels : nil
        preferredFontSize = fontSize
        if segmentCount != fullLabels.count { segmentCount = fullLabels.count; displayedLabels = [] }
        updateLabelsForWidth()
        for (index, title) in fullLabels.enumerated() { setToolTip(title, forSegment: index) }
    }

    override func layout() {
        super.layout()
        updateLabelsForWidth()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLabelsForWidth()
    }

    private func updateLabelsForWidth() {
        let available = bounds.width > 0 ? bounds.width : .greatestFiniteMagnitude
        var titles = fullLabels
        var pointSize = preferredFontSize
        if let compactLabels, requiredWidth(for: titles, fontSize: pointSize) > available {
            titles = compactLabels
            if requiredWidth(for: titles, fontSize: pointSize) > available { pointSize = min(preferredFontSize, 10) }
        }
        if font?.pointSize != pointSize { font = .systemFont(ofSize: pointSize) }
        guard displayedLabels != titles else { return }
        displayedLabels = titles
        for (index, title) in titles.enumerated() {
            setLabel(title, forSegment: index)
            setWidth(0, forSegment: index)
        }
    }

    private func requiredWidth(for labels: [String], fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        let textWidth = labels.reduce(CGFloat(0)) { total, title in
            total + (title as NSString).size(withAttributes: [.font: font]).width
        }
        // Reserve native segment padding and dividers as well as the full text width.
        return textWidth + CGFloat(labels.count * 16 + max(0, labels.count - 1))
    }
}
