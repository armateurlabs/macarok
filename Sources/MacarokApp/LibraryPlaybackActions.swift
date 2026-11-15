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
    }
}
