import AppKit
import Combine
import Foundation
import KeyboardShortcuts
import MacarokAudio
import MacarokCore
import MacarokMetadata
import MediaPlayer
import Observation
import SwiftUI

struct QueueItem: Identifiable, Equatable {
    let id = UUID()
    var track: TrackRecord
}

struct AppMessage: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
}

struct CertificatePrompt: Identifiable {
    var id: UUID { challenge.id }
    let challenge: ServerCertificateChallenge
    let completion: (Bool) -> Void
}

typealias LocalScanOperation = @Sendable (SourceRecord, @escaping @Sendable (Int, Int) -> Void) async throws -> LibraryScanResult

@MainActor @Observable
final class AppModel {
    let player = VLCPlaybackEngine()
    var settings = AppPreferences.load() { didSet { if registerSystemControls { settings.save() }; player.volume = settings.volume } }
    var sources: [SourceRecord] = []
    var sourceID: String? { didSet { if oldValue != sourceID { lyricsTask?.cancel(); lyrics = nil; isLoadingLyrics = false; selectedTrackID = nil; selectedAlbumID = nil; selectedArtist = nil; selectedFolder = nil; search = ""; reloadLibrary(); watchSelectedSource() } } }
    var libraryView: LibraryView = .home { didSet { if libraryView == .home { contextPage = .home; search = "" } } }
    var contextPage: ContextPage = .home
    var contextTab = "Overview"
    var search = "" { didSet { searchLibrary() } }
    var tracks: [TrackRecord] = []
    var searchResults: [TrackRecord] = []
    var selectedTrackID: String?
    var selectedAlbumID: String?
    var selectedArtist: String?
    var selectedFolder: String?
    var queue: [QueueItem] = []
    var currentQueueID: UUID?
    var selectedQueueID: UUID?
    var playlists: [PlaylistRecord] = []
    var isRefreshing = false
    var refreshProgress = ""
    var status = "Add a music folder or connect a source to get started."
    var message: AppMessage?
    var showAddSource = false
    var editingTrack: TrackRecord?
    var artworkTrack: TrackRecord?
    var certificatePrompts: [CertificatePrompt] = []
    var lyrics: String?
    var isLoadingLyrics = false
    var artworkRevision = 0
    var streamingBufferFraction: Double?
    var scanWarnings: [String] = []
    @ObservationIgnored var store: LibraryStore?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = UUID()
    @ObservationIgnored private var refreshSourceID: String?
    @ObservationIgnored private var pendingRescanSourceID: String?
    @ObservationIgnored private let localScan: LocalScanOperation
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var activeStream: BufferedHTTPInputStream?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var tick: AnyCancellable?
    @ObservationIgnored private var eventSubscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private var transportCache: [String: SourceTransport] = [:]
    @ObservationIgnored private var accessedFolders: [String: URL] = [:]
    @ObservationIgnored private var artworkTasks: Set<String> = []
    @ObservationIgnored private var heardSeconds: Double = 0
    @ObservationIgnored private var playRecorded = false
    @ObservationIgnored private var restorePosition: Double = 0
    @ObservationIgnored private var lastSavedTick = 0
    @ObservationIgnored private var directoryWatcher: DirectoryWatcher?
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private let registerSystemControls: Bool

    init(store: LibraryStore? = nil, preferences: AppPreferences? = nil, registerSystemControls: Bool = true,
         localScan: @escaping LocalScanOperation = { source, progress in
             try await LibraryScanner().scan(source: source, metadataReader: { try TagLibMetadataService.read(url: $0) }, progress: progress)
         }) {
        self.store = store
        self.registerSystemControls = registerSystemControls
        self.localScan = localScan
        if let preferences { settings = preferences }
    }

    var selectedSource: SourceRecord? { sources.first { $0.id == sourceID } }
    var displayedTracks: [TrackRecord] { search.isEmpty ? tracks : searchResults }
    var albums: [AlbumRecord] { Dictionary(grouping: tracks, by: \.albumID).values.map(AlbumRecord.init).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    var visibleAlbums: [AlbumRecord] { Dictionary(grouping: displayedTracks, by: \.albumID).values.map(AlbumRecord.init).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    var artists: [ArtistSummary] { Dictionary(grouping: displayedTracks, by: \.albumArtist).map { ArtistSummary(name: $0.key, sourceID: sourceID ?? "", tracks: $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var currentIndex: Int? { queue.firstIndex { $0.id == currentQueueID } }
    var currentTrack: TrackRecord? { queue.first { $0.id == currentQueueID }?.track }
    var selectedTrack: TrackRecord? { selectedTrackID.flatMap { id in tracks.first { $0.id == id } ?? queue.first { $0.track.id == id }?.track } ?? currentTrack }
    var selectedAlbum: AlbumRecord? { albums.first { $0.id == selectedAlbumID } ?? selectedTrack.flatMap { track in albums.first { $0.id == track.albumID } } }
    var queueDuration: Double { queue.reduce(0) { $0 + $1.track.duration } }
    var recentlyAdded: [AlbumRecord] { Array(albums.sorted { $0.addedAt > $1.addedAt }.prefix(8)) }
    var recentlyPlayed: [TrackRecord] { Array(tracks.filter { $0.lastPlayedAt != nil }.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }.prefix(8)) }
    var mostPlayedTracks: [TrackRecord] { Array(tracks.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }.prefix(8)) }
    var mostPlayedAlbums: [AlbumRecord] { Array(albums.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }.prefix(8)) }
    var mostPlayedArtists: [ArtistSummary] { Array(Dictionary(grouping: tracks, by: \.albumArtist).map { ArtistSummary(name: $0.key, sourceID: sourceID ?? "", tracks: $0.value) }.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }.prefix(8)) }

    func start() async {
        guard !started else { return }; started = true
        do {
            if store == nil { store = try LibraryStore(url: LibraryStore.defaultURL) }
            sources = try store!.sources()
            let previous = UserDefaults.standard.string(forKey: "Macarok.selectedSource")
            sourceID = sources.first(where: { $0.id == previous })?.id ?? sources.first?.id
            playlists = try store!.playlists()
            if let snapshot = try store!.loadQueue() {
                let restored = try snapshot.trackIDs.enumerated().compactMap { index, id in
                    try store!.track(id: id).map { (originalIndex: index, item: QueueItem(track: $0)) }
                }
                queue = restored.map(\.item)
                if let current = restored.first(where: { $0.originalIndex == snapshot.currentIndex }) {
                    currentQueueID = current.item.id; restorePosition = snapshot.position
                } else {
                    currentQueueID = restored.first(where: { $0.originalIndex > snapshot.currentIndex })?.item.id ?? restored.last?.item.id
                }
            }
            player.volume = settings.volume
            player.onCompletion = { [weak self] in self?.advance(manual: false) }
            player.onError = { [weak self] error in self?.fail("Playback failed", error) }
            if registerSystemControls {
                configureControls()
                tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.playbackTick() }
                NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.saveQueue() }
                }.store(in: &eventSubscriptions)
            }
            status = sources.isEmpty ? "Add a music folder or connect a source to get started." : "Library is up to date."
        } catch { fail("Could not open the library", error.localizedDescription) }
    }

    func reloadLibrary() {
        guard let store, let sourceID else { tracks = []; searchResults = []; return }
        do {
            tracks = try store.tracks(sourceID: sourceID)
            searchLibrary()
            if registerSystemControls { UserDefaults.standard.set(sourceID, forKey: "Macarok.selectedSource") }
        } catch { fail("Could not read the library", error.localizedDescription) }
    }

    private func searchLibrary() {
        searchTask?.cancel()
        guard let store, let sourceID, !search.isEmpty else { searchResults = tracks; return }
        let query = search
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(160))
                let result = try await Task.detached(priority: .userInitiated) { try store.tracks(sourceID: sourceID, query: query) }.value
                guard !Task.isCancelled, self?.sourceID == sourceID, self?.search == query else { return }
                self?.searchResults = result
            } catch is CancellationError {} catch { self?.fail("Search failed", error.localizedDescription) }
        }
    }

    func inspect(_ track: TrackRecord) {
        lyricsTask?.cancel()
        selectedTrackID = track.id; selectedAlbumID = track.albumID; selectedArtist = track.albumArtist
        contextPage = .track; lyrics = nil
        if contextTab == "Lyrics" { loadLyrics() }
    }

    func inspect(_ album: AlbumRecord) { selectedAlbumID = album.id; selectedTrackID = album.tracks.first?.id; selectedArtist = album.artist; contextPage = .album }
    func inspectArtist(_ name: String) { selectedArtist = name; contextPage = .artist }
    func showCurrentTrack() {
        guard let track = currentTrack else { return }
        if sourceID != track.sourceID { sourceID = track.sourceID }
        inspect(track)
    }

    func add(_ values: [TrackRecord], play: Bool = false) {
        guard !values.isEmpty else { return }
        let new = values.filter(\.isAvailable).map { QueueItem(track: $0) }
        guard !new.isEmpty else { fail("Tracks unavailable", "The selected files are no longer available. Rescan the source after reconnecting it."); return }
        queue.append(contentsOf: new)
        status = new.count == 1 ? "Added “\(new[0].track.title)” to the active playlist." : "Added \(new.count) tracks to the active playlist."
        saveQueue()
        if play, let first = new.first { playQueueItem(first.id) }
    }

    func doubleClick(_ track: TrackRecord) { add([track], play: settings.doubleClickPlays) }

    func playQueueItem(_ id: UUID) {
        guard let item = queue.first(where: { $0.id == id }) else { return }
        let resume = id == currentQueueID ? restorePosition : 0
        restorePosition = 0
        playbackTask?.cancel(); activeStream?.close(); activeStream = nil
        player.stop(); currentQueueID = id; heardSeconds = 0; playRecorded = false
        playbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard self.currentQueueID == id, self.queue.contains(where: { $0.id == id }) else { return }
                guard let source = self.sources.first(where: { $0.id == item.track.sourceID }) else { throw AppFailure.missingSource }
                if source.kind == .local {
                    _ = self.accessFolder(source)
                    guard let url = item.track.url, FileManager.default.fileExists(atPath: url.path) else { throw AppFailure.missingFile }
                    self.player.load(url: url, segmentStart: item.track.startTime ?? 0, segmentEnd: item.track.endTime, bufferSeconds: self.settings.buffer, durationHint: item.track.duration)
                } else {
                    let transport = self.transport(for: source)
                    let url: URL
                    if source.kind == .openSubsonic {
                        guard let remoteID = item.track.remoteID else { throw AppFailure.missingFile }
                        url = try self.subsonicClient(source).streamURL(songID: remoteID)
                    } else { guard let enclosure = item.track.url else { throw AppFailure.missingFile }; url = enclosure }
                    let targetBytes = Int((self.settings.buffer ?? 20) * 192_000)
                    let stream = BufferedHTTPInputStream(url: url, transport: transport, bufferBytes: targetBytes, bufferSeconds: self.settings.buffer, durationHint: item.track.duration)
                    self.activeStream = stream
                    self.player.load(stream: stream, segmentStart: item.track.startTime ?? 0, segmentEnd: item.track.endTime, bufferSeconds: self.settings.buffer, durationHint: item.track.duration)
                }
                if resume > 0 { self.player.seek(to: resume) }
                self.status = "Playing “\(item.track.title)”."
                self.updateNowPlaying(); self.saveQueue()
            } catch is CancellationError { }
            catch { if !Task.isCancelled, self.currentQueueID == id { self.fail("Could not play the track", error.localizedDescription) } }
        }
    }

    func togglePlayback() {
        if player.state == .stopped || player.state == .failed {
            if let id = currentQueueID ?? queue.first?.id { playQueueItem(id) }
            else if let track = selectedTrack { add([track], play: true) }
        } else { player.togglePlayPause(); updateNowPlaying(); saveQueue() }
    }

    func advance(manual: Bool = true) {
        guard let index = currentIndex else { if let first = queue.first { playQueueItem(first.id) }; return }
        if !manual && settings.repeatMode == .track { playQueueItem(queue[index].id) }
        else if index + 1 < queue.count { playQueueItem(queue[index + 1].id) }
        else if settings.repeatMode == .playlist, let first = queue.first { playQueueItem(first.id) }
        else { playbackTask?.cancel(); player.stop(); activeStream?.close(); activeStream = nil; status = "Playback finished."; saveQueue(); updateNowPlaying() }
    }

    func previous() {
        if player.position > 3 { player.seek(to: 0); return }
        guard let index = currentIndex else { return }
        if index > 0 { playQueueItem(queue[index - 1].id) }
        else if settings.repeatMode == .playlist, let last = queue.last { playQueueItem(last.id) }
        else { player.seek(to: 0) }
    }

    func shuffle(_ values: [TrackRecord]) {
        guard !values.isEmpty else { return }
        let available = values.filter(\.isAvailable)
        guard !available.isEmpty else { fail("Tracks unavailable", "Reconnect the source and refresh its library before shuffling these tracks."); return }
        queue = available.shuffled().map { QueueItem(track: $0) }
        if let first = queue.first { playQueueItem(first.id) }
    }
    func shuffleQueue() {
        if let index = currentIndex { let current = queue.remove(at: index); queue.shuffle(); queue.insert(current, at: 0); currentQueueID = current.id }
        else { queue.shuffle() }
        saveQueue()
    }
    func moveQueue(from offsets: IndexSet, to destination: Int) { queue.move(fromOffsets: offsets, toOffset: destination); saveQueue() }
    func removeQueue(_ offsets: IndexSet) {
        let deletingCurrent = offsets.contains { queue[$0].id == currentQueueID }
        queue.remove(atOffsets: offsets)
        if deletingCurrent { playbackTask?.cancel(); player.stop(); activeStream?.close(); currentQueueID = nil; restorePosition = 0; updateNowPlaying() }
        saveQueue()
    }
    func clearQueue() { playbackTask?.cancel(); player.stop(); activeStream?.close(); queue = []; currentQueueID = nil; restorePosition = 0; saveQueue(); updateNowPlaying() }
    func cycleRepeat() { settings.repeatMode = settings.repeatMode.next }

    func saveQueue() {
        try? store?.saveQueue(trackIDs: queue.map(\.track.id), currentIndex: currentIndex ?? 0, position: player.position > 0 ? player.position : restorePosition)
    }

    func pickFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Add Music Folder"; panel.message = "Choose a folder to index. Your audio files stay in their current location."
        if panel.runModal() == .OK, let url = panel.url { addFolder(url) }
    }

    func addFolder(_ url: URL) {
        if let existing = sources.first(where: { $0.kind == .local && $0.url?.standardizedFileURL == url.standardizedFileURL }) { sourceID = existing.id; refresh(); return }
        do {
            let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            let source = SourceRecord(kind: .local, name: url.lastPathComponent, location: url.absoluteString, bookmarkData: bookmark)
            try store?.saveSource(source); sources = try store?.sources() ?? []; sourceID = source.id
            refresh()
        } catch { fail("Could not add the folder", error.localizedDescription) }
    }

    func addServer(name: String, address: String, credentials: SourceCredentials) async throws {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw SourceNetworkError.invalidURL }
        let source = SourceRecord(kind: .openSubsonic, name: name.isEmpty ? (url.host ?? "Music Server") : name, location: url.absoluteString)
        try KeychainCredentialStore.shared.save(credentials, sourceID: source.id)
        do {
            let client = OpenSubsonicClient(baseURL: url, credentials: credentials, transport: transport(for: source))
            _ = try await client.ping()
            try store?.saveSource(source)
        } catch {
            try? KeychainCredentialStore.shared.delete(sourceID: source.id)
            CertificateTrustStore.shared.revoke(sourceID: source.id)
            transportCache.removeValue(forKey: source.id)?.invalidate()
            throw error
        }
        sources = try store?.sources() ?? []; sourceID = source.id
        refresh()
    }

    func addPodcast(address: String) async throws {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw SourceNetworkError.invalidURL }
        if let existing = sources.first(where: { $0.kind == .podcasts && $0.location == url.absoluteString }) { sourceID = existing.id; return }
        var source = SourceRecord(kind: .podcasts, name: url.host ?? "Podcast", location: url.absoluteString)
        let feed: PodcastFeed
        do { feed = try await PodcastClient(transport: transport(for: source)).fetchFeed(url: url) }
        catch {
            transportCache.removeValue(forKey: source.id)?.invalidate()
            CertificateTrustStore.shared.revoke(sourceID: source.id)
            throw error
        }
        source.name = feed.title
        try store?.saveSource(source)
        let artwork = try? await cachePodcastArtwork(feed: feed, source: source)
        try store?.upsertTracks(feed.episodes.map { $0.asTrackRecord(sourceID: source.id, feed: feed, artworkPath: artwork?.path) })
        sources = try store?.sources() ?? []; sourceID = source.id
        reloadLibrary(); status = "Subscribed to “\(source.name)”."
    }

    func removeSource(_ source: SourceRecord) {
        do {
            if refreshSourceID == source.id { refreshTask?.cancel() }
            if currentTrack?.sourceID == source.id { playbackTask?.cancel(); player.stop(); activeStream?.close(); currentQueueID = nil; restorePosition = 0; updateNowPlaying() }
            queue.removeAll { $0.track.sourceID == source.id }
            try store?.deleteSource(id: source.id); try KeychainCredentialStore.shared.delete(sourceID: source.id)
            CertificateTrustStore.shared.revoke(sourceID: source.id)
            accessedFolders.removeValue(forKey: source.id)?.stopAccessingSecurityScopedResource()
            transportCache.removeValue(forKey: source.id)?.invalidate()
            sources = try store?.sources() ?? []
            if sourceID == source.id { sourceID = sources.first?.id }
            reloadLibrary(); saveQueue()
        } catch { fail("Could not remove the source", error.localizedDescription) }
    }

    func refresh() {
        guard let source = selectedSource, let store else { return }
        refreshTask?.cancel()
        let generation = UUID()
        refreshGeneration = generation
        refreshSourceID = source.id
        isRefreshing = true; refreshProgress = "Connecting…"; scanWarnings = []
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.refreshGeneration == generation {
                    self.isRefreshing = false
                    self.refreshSourceID = nil
                    if let pending = self.pendingRescanSourceID {
                        self.pendingRescanSourceID = nil
                        if self.sourceID == pending { self.refresh() }
                    }
                }
            }
            do {
                switch source.kind {
                case .local:
                    let resolved = self.accessFolder(source)
                    var scanSource = source
                    if let resolved { scanSource.location = resolved.absoluteString }
                    let result = try await self.localScan(scanSource, { [weak self] count, total in
                        Task { @MainActor in if self?.refreshGeneration == generation { self?.refreshProgress = "Reading file \(count) of \(total)…" } }
                    })
                    try Task.checkCancellation()
                    if result.isComplete { try store.replaceSourceTracks(sourceID: source.id, with: result.tracks) }
                    else { try store.upsertTracks(result.tracks) }
                    self.scanWarnings = result.warnings
                case .openSubsonic:
                    let client = try self.subsonicClient(source)
                    let remote = try await client.fetchLibrary(sourceID: source.id, progress: { [weak self] done, total in Task { @MainActor in if self?.refreshGeneration == generation { self?.refreshProgress = "Reading album \(done) of \(total)…" } } })
                    try Task.checkCancellation()
                    try store.replaceSourceTracks(sourceID: source.id, with: remote.map { $0.asTrackRecord(sourceID: source.id) })
                case .podcasts:
                    guard let url = source.url else { throw SourceNetworkError.invalidURL }
                    let feed = try await PodcastClient(transport: self.transport(for: source)).fetchFeed(url: url)
                    let artwork = try? await self.cachePodcastArtwork(feed: feed, source: source)
                    try Task.checkCancellation()
                    try store.upsertTracks(feed.episodes.map { $0.asTrackRecord(sourceID: source.id, feed: feed, artworkPath: artwork?.path) })
                }
                guard self.refreshGeneration == generation else { return }
                self.reloadLibrary()
                self.status = self.scanWarnings.isEmpty ? "“\(source.name)” is up to date." : "Scan completed with \(self.scanWarnings.count) warnings."
            } catch is CancellationError { if self.refreshGeneration == generation { self.status = "Refresh cancelled." } }
            catch { if self.refreshGeneration == generation { self.fail("Could not refresh “\(source.name)”", error.localizedDescription) } }
        }
    }

    func cancelRefresh() { refreshTask?.cancel() }

    private func watchSelectedSource() {
        directoryWatcher?.stop(); directoryWatcher = nil; rescanTask?.cancel()
        pendingRescanSourceID = nil
        guard registerSystemControls, let source = selectedSource, source.kind == .local, let url = accessFolder(source) else { return }
        let watchedURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        directoryWatcher = DirectoryWatcher(url: watchedURL) { [weak self] in
            Task { @MainActor in
                guard let self, self.sourceID == source.id else { return }
                self.rescanTask?.cancel()
                self.rescanTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self else { return }
                    self.requestRescan(sourceID: source.id)
                }
            }
        }
    }

    func requestRescan(sourceID: String) {
        guard self.sourceID == sourceID, selectedSource?.kind == .local else { return }
        if isRefreshing { pendingRescanSourceID = sourceID }
        else { refresh() }
    }

    @discardableResult func accessFolder(_ source: SourceRecord) -> URL? {
        if let existing = accessedFolders[source.id] { return existing }
        var resolved = source.url
        if let data = source.bookmarkData {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                resolved = url
                if stale, let renewed = try? url.bookmarkData(options: .withSecurityScope) { var updated = source; updated.bookmarkData = renewed; try? store?.saveSource(updated) }
            }
        }
        if let resolved { _ = resolved.startAccessingSecurityScopedResource(); accessedFolders[source.id] = resolved }
        return resolved
    }

    func transport(for source: SourceRecord) -> SourceTransport {
        if let existing = transportCache[source.id] { return existing }
        let value = SourceTransport(sourceID: source.id, certificateApproval: { [weak self] challenge in
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    guard let self else { continuation.resume(returning: false); return }
                    self.certificatePrompts.append(CertificatePrompt(challenge: challenge, completion: { continuation.resume(returning: $0) }))
                }
            }
        })
        transportCache[source.id] = value
        return value
    }

    func answerCertificate(_ accepted: Bool) {
        guard !certificatePrompts.isEmpty else { return }
        let prompt = certificatePrompts.removeFirst(); prompt.completion(accepted)
    }

    func subsonicClient(_ source: SourceRecord) throws -> OpenSubsonicClient {
        guard let url = source.url, let credentials = try KeychainCredentialStore.shared.load(sourceID: source.id) else { throw SourceNetworkError.missingCredentials }
        return OpenSubsonicClient(baseURL: url, credentials: credentials, transport: transport(for: source))
    }

    func ensureArtwork(_ track: TrackRecord) async {
        guard track.artworkPath == nil, let cover = track.coverArtID, !artworkTasks.contains(track.albumID), let source = sources.first(where: { $0.id == track.sourceID }), source.kind == .openSubsonic else { return }
        artworkTasks.insert(track.albumID)
        defer { artworkTasks.remove(track.albumID) }
        do {
            let data = try await subsonicClient(source).coverArt(id: cover)
            let url = try cacheArtwork(data, key: StableID.make(source.id, cover))
            for var sibling in try store?.tracks(sourceID: source.id) ?? [] where sibling.albumID == track.albumID {
                sibling.artworkPath = url.path
                try store?.upsertTracks([sibling])
            }
            reloadLibrary(); artworkRevision += 1
        } catch { }
    }

    func cacheArtwork(_ data: Data, key: String) throws -> URL {
        guard NSImage(data: data) != nil else { throw AppFailure.invalidArtwork }
        let databaseURL = store.map { URL(fileURLWithPath: $0.database.path) } ?? LibraryStore.defaultURL
        let directory = databaseURL.deletingLastPathComponent().appendingPathComponent("Artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(key + ".image")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func cachePodcastArtwork(feed: PodcastFeed, source: SourceRecord) async throws -> URL? {
        guard let url = feed.artworkURL else { return nil }
        let data = try await transport(for: source).data(from: url)
        return try cacheArtwork(data, key: StableID.make(source.id, "podcast-artwork"))
    }

    func loadLyrics() {
        guard let track = selectedTrack else { return }
        lyricsTask?.cancel()
        isLoadingLyrics = true; lyrics = nil
        lyricsTask = Task {
            defer { if !Task.isCancelled { isLoadingLyrics = false } }
            do {
                let result: String?
                if let source = sources.first(where: { $0.id == track.sourceID }), source.kind == .openSubsonic, let remoteID = track.remoteID {
                    result = try await subsonicClient(source).lyrics(songID: remoteID)
                } else if let url = track.url, url.isFileURL {
                    let properties = try await Task.detached { try TagLibMetadataService.properties(url: url) }.value
                    let embedded = properties["LYRICS"]?.joined(separator: "\n")
                    result = embedded?.isEmpty == false ? embedded : try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("lrc"), encoding: .utf8)
                } else { result = nil }
                guard !Task.isCancelled, selectedTrack?.id == track.id else { return }
                lyrics = result
            } catch { if !Task.isCancelled { status = "Lyrics are unavailable: \(error.localizedDescription)" } }
        }
    }

    func rate(_ track: TrackRecord, value: Int) { do { try store?.setRating(trackID: track.id, rating: value); reloadLibrary() } catch { fail("Could not save rating", error.localizedDescription) } }

    func fail(_ title: String, _ detail: String) { status = detail; message = AppMessage(title: title, detail: detail) }

    func openURL(_ url: URL) {
        Task {
            await start()
            if url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { addFolder(url) }
            else if ["m3u", "m3u8", "pls"].contains(url.pathExtension.lowercased()) { importPlaylist(url) }
            else if url.isFileURL { importAudioFile(url) }
            else { showAddSource = true }
        }
    }

    private func playbackTick() {
        if let snapshot = activeStream?.snapshot, snapshot.isBuffering {
            streamingBufferFraction = min(1, Double(snapshot.bufferedBytes) / Double(max(1, snapshot.targetBytes)))
        } else { streamingBufferFraction = nil }
        if player.state == .playing, let track = currentTrack {
            heardSeconds += 1
            let duration = player.duration > 0 ? player.duration : track.duration
            let threshold = min(240, max(1, duration > 0 ? duration / 2 : 240))
            if !playRecorded && heardSeconds >= threshold {
                try? store?.recordPlay(trackID: track.id, at: Date()); playRecorded = true; reloadLibrary()
            }
        }
        updateNowPlaying()
        lastSavedTick += 1
        if lastSavedTick >= 5 { lastSavedTick = 0; saveQueue() }
    }

    private func configureControls() {
        let commands = MPRemoteCommandCenter.shared()
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlayback() }; return .success }
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in
            guard let self else { return }
            if self.player.state == .stopped || self.player.state == .failed { self.togglePlayback() }
            else { self.player.play() }
        }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.player.pause() }; return .success }
        commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.advance() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.player.seek(to: event.positionTime) }; return .success
        }
        KeyboardShortcuts.onKeyUp(for: .playPause) { [weak self] in self?.togglePlayback() }
        KeyboardShortcuts.onKeyUp(for: .nextTrack) { [weak self] in self?.advance() }
        KeyboardShortcuts.onKeyUp(for: .previousTrack) { [weak self] in self?.previous() }
        KeyboardShortcuts.onKeyUp(for: .showMacarok) { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first?.makeKeyAndOrderFront(nil) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, !event.isARepeat else { return event }
            let editing = NSApp.keyWindow?.firstResponder is NSTextView
            if !editing, let shortcut = KeyboardShortcuts.Shortcut(event: event) {
                for name in ["playPause", "previousTrack", "nextTrack", "addToPlaylist", "search", "showCurrentTrack"] where self.localShortcut(name) == shortcut {
                    self.performLocalShortcut(name)
                    return nil
                }
            }
            return event
        }) { monitors.append(monitor) }
    }

    private func updateNowPlaying() {
        guard let track = currentTrack else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artist, MPMediaItemPropertyAlbumTitle: track.album, MPMediaItemPropertyPlaybackDuration: player.duration > 0 ? player.duration : track.duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: player.position, MPNowPlayingInfoPropertyPlaybackRate: player.state == .playing ? 1.0 : 0.0]
        MPNowPlayingInfoCenter.default().playbackState = player.state == .playing ? .playing : player.state == .paused ? .paused : .stopped
    }
}

enum AppFailure: LocalizedError {
    case missingSource, missingFile, invalidArtwork
    var errorDescription: String? {
        switch self {
        case .missingSource: "This track's source is no longer configured."
        case .missingFile: "The audio file is unavailable. Reconnect the source and refresh its library."
        case .invalidArtwork: "The selected image could not be read."
        }
    }
}
