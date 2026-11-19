import AppKit
import MacarokCore
import SwiftUI

struct TrackFileActions: View {
    @Bindable var model: AppModel
    let track: TrackRecord
    var body: some View {
        if model.supportsDownloads(track), let controller = model.podcastDownloads {
            let key = PodcastDownloadsController.key(track)
            Divider()
            if let download = controller.downloads[key] {
                Button("Reveal in Finder", systemImage: "folder") { controller.reveal(download) }
                Button("Remove Download", systemImage: "trash") { controller.remove(download) }
                    .disabled(!controller.canRemove(download))
            } else if controller.isDownloading(track) {
                Button("Cancel Download", systemImage: "xmark.circle") { controller.cancel(track) }
            } else {
                Button(model.downloadActionTitle(track), systemImage: "arrow.down.circle") { controller.download(track) }
            }
        } else if let url = track.url, url.isFileURL {
            Divider()
            Button("Reveal in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        Button("Share…", systemImage: "square.and.arrow.up") { model.share(track) }
    }
}

struct PodcastEpisodeActions: View {
    @Bindable var model: AppModel
    let track: TrackRecord
    var body: some View {
        if model.supportsDownloads(track), let controller = model.podcastDownloads {
            let key = PodcastDownloadsController.key(track)
            HStack(spacing: 10) {
                if let download = controller.downloads[key] {
                    Label("Downloaded", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    Button("Reveal in Finder") { controller.reveal(download) }
                } else if let progress = controller.progress[key] {
                    if let fraction = progress.fraction { ProgressView(value: fraction).frame(width: 95) }
                    else { ProgressView().controlSize(.small) }
                    Text(progress.fraction.map { "Downloading \(Int($0 * 100))%" } ?? "Downloading…").foregroundStyle(.secondary)
                    Button("Cancel") { controller.cancel(track) }
                } else {
                    Button(model.downloadActionTitle(track), systemImage: "arrow.down.circle") { controller.download(track) }
                }
                Spacer(minLength: 0)
            }.font(.system(size: 11)).controlSize(.small).padding(.vertical, 6)
        }
    }
}
