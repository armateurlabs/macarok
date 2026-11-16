import AppKit
import SwiftUI

/// Panel actions share one opaque toolbar surface, separate from the window status bar.
struct PanelFooter<Content: View>: View {
    static var height: CGFloat { 42 }
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8, content: content)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            .padding(.horizontal, 13)
            .frame(height: Self.height)
            .background {
                Color(nsColor: .controlBackgroundColor).overlay(Color.primary.opacity(0.05))
            }
            .overlay(alignment: .top) { Color(nsColor: .separatorColor).frame(height: 0.5) }
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum LibraryFooterSummary {
    case music(albums: Int, tracks: Int)
    case radio(stations: Int)

    var title: String {
        switch self {
        case let .music(albums, tracks): "\(albums) albums · \(tracks) tracks"
        case let .radio(stations): "\(stations) stations"
        }
    }
}

struct LibraryPanelFooter: View {
    @Bindable var model: AppModel
    let summary: LibraryFooterSummary

    var body: some View {
        PanelFooter {
            GeometryReader { geometry in
                HStack(spacing: 8) {
                    counts(compact: geometry.size.width < max(335, fullCountWidth + 160))
                        .font(.system(size: 10)).monospacedDigit()
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .help(summary.title).accessibilityLabel(summary.title)
                    LibraryRefreshControl(model: model, compact: geometry.size.width < 270)
                }.frame(height: 42)
            }
        }.accessibilityIdentifier("libraryPanelFooter")
    }

    @ViewBuilder private func counts(compact: Bool) -> some View {
        if compact {
            switch summary {
            case let .music(albums, tracks):
                HStack(spacing: 8) {
                    Label(shortCount(albums), systemImage: "opticaldisc")
                    Label(shortCount(tracks), systemImage: "music.note")
                }
            case let .radio(stations): Label(shortCount(stations), systemImage: "antenna.radiowaves.left.and.right")
            }
        } else { Text(summary.title) }
    }

    private func shortCount(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    private var fullCountWidth: CGFloat {
        (summary.title as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)]).width
    }
}

struct PlaylistPanelFooter: View {
    @Bindable var model: AppModel

    var body: some View {
        PanelFooter {
            Spacer(minLength: 0)
            PlaylistControls(model: model, location: "bottom")
        }.accessibilityIdentifier("playlistPanelFooter")
    }
}
