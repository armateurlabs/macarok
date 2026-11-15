import AppKit
import SwiftUI

/// Two stable header rows keep navigation centered independently of the displayed content.
struct CenterPanelHeader: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader {
                CenterSegmentedPicker(selection: Binding(get: { model.centerPage == .home ? 0 : 1 }, set: {
                    model.centerPage = $0 == 0 ? .home : .playing
                }), labels: ["Home", "Playing"], label: "Center panel", identifier: "centerPagePicker", maximumWidth: 208)
                .frame(width: 208).frame(maxWidth: .infinity)
            }.accessibilityIdentifier("contextPanelHeader")

            PanelHeader {
                Group {
                    if model.centerPage == .home {
                        CenterSegmentedPicker(selection: Binding(get: { HomeFilter.allCases.firstIndex(of: model.homeFilter) ?? 0 }, set: {
                            guard HomeFilter.allCases.indices.contains($0) else { return }
                            model.homeFilter = HomeFilter.allCases[$0]
                        }), labels: HomeFilter.allCases.map(\.title), label: "Home filter", identifier: "homeFilterPicker",
                                              maximumWidth: 522, fontSize: 11, proportional: true)
                            .frame(maxWidth: 522)
                    } else {
                        CenterSegmentedPicker(selection: Binding(get: { ContextMode.allCases.firstIndex(of: model.contextMode) ?? 0 }, set: {
                            guard ContextMode.allCases.indices.contains($0) else { return }
                            model.contextMode = ContextMode.allCases[$0]
                        }), labels: ContextMode.allCases.map(\.title), label: "Playing view", identifier: "playingViewPicker", maximumWidth: 382)
                            .frame(maxWidth: 382)
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
        control.font = .systemFont(ofSize: fontSize)
        control.segmentDistribution = proportional ? .fillProportionally : .fillEqually
        control.segmentCount = labels.count
        for (index, title) in labels.enumerated() {
            control.setLabel(title, forSegment: index)
            control.setWidth(0, forSegment: index)
        }
        control.selectedSegment = labels.indices.contains(selection) ? selection : -1
        control.setAccessibilityLabel(label)
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
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }
}
