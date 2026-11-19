import Foundation
import MacarokCore

extension AppModel {
    var isRadioSource: Bool { selectedSource?.kind == .radio }
    func isRadioTrack(_ track: TrackRecord?) -> Bool {
        guard let track else { return false }
        return track.sourceID == RadioLibrary.sourceID || radioSourceIDs.contains(track.sourceID)
    }
    var currentIsRadio: Bool { isRadioTrack(currentTrack) }
    var radioStations: [RadioStationRecord] {
        let sourceIDs = Set(sources.filter { $0.kind == .radio && scopeIncludes(sourceID: $0.id) }.map(\.id))
        return (radio?.stations ?? []).filter { station in
            sourceIDs.contains(station.sourceID) && (search.isEmpty || [station.name,station.description,station.tags].joined(separator: " ").localizedStandardContains(search))
        }
    }

    func reconnectRadio() {
        guard currentIsRadio, let id = currentQueueID else { return }
        playQueueItem(id)
    }

    func loadRadio(item: QueueItem, source: SourceRecord, generation: UUID) async throws {
        guard let station = try await performLibraryWork({ try $0.radioStation(id: item.track.id) }) else { throw AppFailure.missingFile }
        guard !station.isHLS else { throw RadioError.unsupportedHLS }
        let transport = transport(for: source)
        let url = try RadioError.validatedURL(station.resolvedURL ?? station.streamURL)
        let resolved = try await RadioStreamResolver.resolve(url, transport: transport)
        try Task.checkCancellation()
        guard playbackGeneration == generation, currentQueueID == item.id, queue.contains(where: { $0.id == item.id }) else { throw CancellationError() }
        let stream = BufferedHTTPInputStream(url: resolved, transport: transport,
                                            bufferSeconds: settings.buffer, live: true, onTitle: { [weak self] title in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation, self.currentQueueID == item.id,
                      self.currentIsRadio, !self.radioDisconnected else { return }
                // An empty StreamTitle means the station is not announcing a track.
                self.radioBroadcastTitle = title.isEmpty ? nil : title
            }
        }, onStationInfo: { [weak self] info in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation, self.currentQueueID == item.id else { return }
                self.radioStreamInfo = info.isEmpty ? nil : info
            }
        })
        activeStream = stream
        player.load(stream: stream, bufferSeconds: settings.buffer, live: true)
    }
}
