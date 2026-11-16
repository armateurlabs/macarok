import MacarokCore
import SwiftUI

struct LibraryPlaybackActions: View {
    @Bindable var model: AppModel
    var addTitle = "Add to Active Playlist"
    let tracks: () -> [TrackRecord]

    var body: some View {
        Button { model.add(tracks(), play: true) } label: {
            Label("Play Now", systemImage: "play.fill")
        }
        Button(addTitle) { model.add(tracks()) }
        Button("Add After Current Track") { model.addAfterCurrent(tracks()) }
        Divider()
        SimilarityActions(model: model, tracks: tracks)
    }
}

struct AlbumMetadataAction: View {
    @Bindable var model: AppModel
    let album: AlbumRecord
    var body: some View {
        Divider()
        Button("Edit Album Metadata…") {
            if let track = model.tracksForAlbum(album).first { model.beginAlbumMetadataEditing(track) }
        }.disabled(album.tracks.isEmpty)
    }
}
