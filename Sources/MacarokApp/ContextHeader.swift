import MacarokCore
import SwiftUI

/// Shared metrics so every context page (track, album, artist, folder) lines up identically.
enum ContextLayout {
    static let artworkSize: CGFloat = 118
    static let sectionSpacing: CGFloat = 17
    static let headerSpacing: CGFloat = 16
    static let detailSpacing: CGFloat = 6
    static let titleFont = Font.system(size: 23, weight: .semibold)
}

/// Eyebrow label, then artwork on the left and the item's details on the right.
struct ContextHeader<Artwork: View, Details: View>: View {
    let eyebrow: String
    @ViewBuilder let artwork: Artwork
    @ViewBuilder let details: Details

    var body: some View {
        VStack(alignment: .leading, spacing: ContextLayout.sectionSpacing) {
            Text(eyebrow.uppercased()).font(.system(size: 10, weight: .medium)).tracking(1).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: ContextLayout.headerSpacing) {
                artwork.frame(width: ContextLayout.artworkSize, height: ContextLayout.artworkSize)
                VStack(alignment: .leading, spacing: ContextLayout.detailSpacing) { details }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The same playback actions, in the same order and style, under every context header:
/// Add to Playlist · Play Next · Shuffle, with an optional trailing accessory.
struct ContextPlaybackBar<Trailing: View>: View {
    @Bindable var model: AppModel
    var allowsShuffle = true
    let tracks: () -> [TrackRecord]
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Button { model.add(tracks()) } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }
                .buttonStyle(.borderedProminent)
                .help("Add to the end of the active playlist")
            Button { model.addAfterCurrent(tracks()) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                .help("Add After Current Track")
            if allowsShuffle {
                Button { model.shuffle(tracks()) } label: { Label("Shuffle", systemImage: "shuffle") }
                    .help("Shuffle into the active playlist")
            }
            Spacer(minLength: 0)
            trailing
        }.controlSize(.small)
    }
}

extension ContextPlaybackBar where Trailing == EmptyView {
    init(model: AppModel, allowsShuffle: Bool = true, tracks: @escaping () -> [TrackRecord]) {
        self.init(model: model, allowsShuffle: allowsShuffle, tracks: tracks) { EmptyView() }
    }
}

/// Square placeholder used where a context page has no artwork of its own (folders).
struct ContextSymbolArtwork: View {
    let systemImage: String
    var body: some View {
        RoundedRectangle(cornerRadius: 5).fill(.quaternary)
            .overlay { Image(systemName: systemImage).resizable().scaledToFit().foregroundStyle(.tertiary).padding(30) }
    }
}

func pluralized(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(count) \(count == 1 ? singular : plural ?? singular + "s")"
}
