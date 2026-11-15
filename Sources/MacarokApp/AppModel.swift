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
typealias RemoteCatalogOperation = @Sendable (SourceRecord, @escaping @Sendable ([TrackRecord], Int, Int?) async throws -> Void) async throws -> Void
typealias LibrarySnapshotLoader = @Sendable (String, LibraryStore, [SourceRecord]) async throws -> LibrarySnapshot

@MainActor
private final class LibraryReloadState {
    let sourceID: String
    var requestedRevision = 1
    var task: Task<Void, Never>?
    init(sourceID: String) { self.sourceID = sourceID }
}

@MainActor
private final class RemoteCatalogProgress {
    var activeIDs: Set<String> = []
    var revision = 0
    var acceptingBatches = true
    var lastPublished: ContinuousClock.Instant?
    var publicationTask: Task<Void, Never>?
    var publicationError: Error?
}

@MainActor @Observable
final class AppModel {
    let player = VLCPlaybackEngine()
    var settings = AppPreferences.load() { didSet { if registerSystemControls { settings.save() }; player.volume = settings.volume } }
    var sources: [SourceRecord] = []
    var sourceID: String? { didSet { if oldValue != sourceID { lyricsTask?.cancel(); lyrics = nil; isLoadingLyrics = false; selectedTrackID = nil; selectedAlbumID = nil; selectedArtist = nil; selectedFolder = nil; search = ""; reloadLibrary(); watchSelectedSource() } } }
    var libraryView: LibraryView = .home { didSet { if libraryView == .home { contextPage = .home } } }
    var contextPage: ContextPage = .home
    var contextTab = "Overview"
    var search = "" { didSet { searchLibrary(reset: true) } }
    private var catalog = LibrarySnapshot.empty
    private var searchCatalog = LibrarySnapshot.empty
    var tracks: [TrackRecord] { catalog.tracks }
    private(set) var libraryRevision = 0
    var searchResults: [TrackRecord] { searchCatalog.tracks }
    private(set) var isLoadingLibrary = false
    private(set) var isSearching = false
    var snapshotSourceID: String? { catalog.sourceID }
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
    @ObservationIgnored private let remoteCatalog: RemoteCatalogOperation?
    @ObservationIgnored private let snapshotLoader: LibrarySnapshotLoader
    @ObservationIgnored private let backgroundWorker = LibraryBackgroundWorker()
    @ObservationIgnored private var libraryReloadState: LibraryReloadState?
    @ObservationIgnored private var searchRequestID = UUID()
    @ObservationIgnored private var searchNeedsReload = false
    @ObservationIgnored private var queueSaveRevision = 0
    @ObservationIgnored private var remoteCatalogProgress: RemoteCatalogProgress?
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
         }, remoteCatalog: RemoteCatalogOperation? = nil, snapshotLoader: LibrarySnapshotLoader? = nil) {
        self.store = store
        self.registerSystemControls = registerSystemControls
        self.localScan = localScan
        self.remoteCatalog = remoteCatalog
        self.snapshotLoader = snapshotLoader ?? { sourceID, store, sources in
            let task = Task.detached(priority: .userInitiated) {
                try LibrarySnapshot.build(sourceID: sourceID,
                                          tracks: store.tracks(sourceID: sourceID, ordered: false), sources: sources)
            }
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
        if let preferences { settings = preferences }
    }

    var selectedSource: SourceRecord? { sources.first { $0.id == sourceID } }
    private var displayedCatalog: LibrarySnapshot { search.isEmpty ? catalog : searchCatalog }
    var displayedTracks: [TrackRecord] { displayedCatalog.tracks }
    var albums: [AlbumRecord] { catalog.albums }
    var visibleAlbums: [AlbumRecord] { displayedCatalog.albums }
    var artists: [ArtistSummary] { displayedCatalog.artists }
    var yearGroups: [LibraryYearGroup] { displayedCatalog.yearGroups }
    var genreGroups: [LibraryTrackGroup] { displayedCatalog.genreGroups }
    var formatGroups: [LibraryTrackGroup] { displayedCatalog.formatGroups }
    var folderNodes: [FolderNode] { displayedCatalog.folderNodes }
    func tracksForAlbum(_ album: AlbumRecord) -> [TrackRecord] { catalog.albumsByID[album.id]?.tracks ?? album.tracks }
    func albumsForArtist(_ name: String) -> [AlbumRecord] { catalog.artistsByName[name]?.albums ?? [] }
    func artistSummary(named name: String) -> ArtistSummary? { catalog.artistsByName[name] }
    func cachedTracksInFolder(_ path: String) -> [TrackRecord] {
        displayedCatalog.tracksByFolder[path] ?? []
    }
    var currentIndex: Int? { queue.firstIndex { $0.id == currentQueueID } }
    var currentTrack: TrackRecord? { queue.first { $0.id == currentQueueID }?.track }
    var selectedTrack: TrackRecord? { selectedTrackID.flatMap { id in catalog.tracksByID[id] ?? queue.first { $0.track.id == id }?.track } ?? currentTrack }
    var selectedAlbum: AlbumRecord? { selectedAlbumID.flatMap { catalog.albumsByID[$0] } ?? selectedTrack.flatMap { catalog.albumsByID[$0.albumID] } }
    var queueDuration: Double { queue.reduce(0) { $0 + $1.track.duration } }
    var recentlyAdded: [AlbumRecord] { catalog.recentlyAdded }
    var recentlyPlayed: [TrackRecord] { catalog.recentlyPlayed }
    var mostPlayedTracks: [TrackRecord] { catalog.mostPlayedTracks }
    var mostPlayedAlbums: [AlbumRecord] { catalog.mostPlayedAlbums }
    var mostPlayedArtists: [ArtistSummary] { catalog.mostPlayedArtists }

    func start() async {
        guard !started else { return }; started = true
        do {
            if store == nil { store = try await Task.detached { try LibraryStore(url: LibraryStore.defaultURL) }.value }
            let initial = try await performLibraryWork { store in
                let sources = try store.sources()
                let snapshot = try store.loadQueue()
                let restored = try (snapshot?.trackIDs ?? []).enumerated().compactMap { index, id in
                    try store.track(id: id).map { (index, $0) }
                }
                let incomplete = try Set(sources.filter { try store.value(forKey: Self.catalogImportKey($0.id)) != nil }.map(\.id))
                return (sources: sources, playlists: try store.playlists(), queue: snapshot, restored: restored, incomplete: incomplete)
            }
            sources = initial.sources
            let previous = UserDefaults.standard.string(forKey: "Macarok.selectedSource")
            sourceID = sources.first(where: { $0.id == previous })?.id ?? sources.first?.id
            playlists = initial.playlists
            if let snapshot = initial.queue {
                let restored = initial.restored.map { (originalIndex: $0.0, item: QueueItem(track: $0.1)) }
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
            }
            await waitForLibraryLoad()
            if let source = selectedSource, source.kind == .openSubsonic, initial.incomplete.contains(source.id) {
                status = "Catalog import is incomplete. Refresh this source to load the remaining albums."
            } else {
                status = sources.isEmpty ? "Add a music folder or connect a source to get started." : "Library is up to date."
            }
        } catch { fail("Could not open the library", error.localizedDescription) }
    }

    func reloadLibrary() {
        guard let store, let sourceID else {
            libraryReloadState?.task?.cancel(); libraryReloadState = nil
            catalog = .empty; searchCatalog = .empty; libraryRevision &+= 1; isLoadingLibrary = false
            return
        }
        if catalog.sourceID != sourceID {
            catalog = .empty; searchCatalog = .empty; libraryRevision &+= 1
        }
        if let state = libraryReloadState, state.sourceID == sourceID, state.task != nil {
            state.requestedRevision &+= 1
            return
        }
        libraryReloadState?.task?.cancel()
        let state = LibraryReloadState(sourceID: sourceID)
        libraryReloadState = state
        isLoadingLibrary = true
        state.task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let requested = state.requestedRevision
                do {
                    let snapshot = try await self.snapshotLoader(sourceID, store, self.sources)
                    try Task.checkCancellation()
                    guard self.libraryReloadState === state, self.sourceID == sourceID else { break }
                    self.catalog = snapshot
                    self.updateQueuedMetadata(from: snapshot)
                    self.libraryRevision &+= 1
                    self.searchLibrary(reset: false)
                } catch is CancellationError { break }
                catch {
                    if self.libraryReloadState === state, self.sourceID == sourceID { self.fail("Could not read the library", error.localizedDescription) }
                    break
                }
                if state.requestedRevision == requested { break }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
            }
            state.task = nil
            if self.libraryReloadState === state { self.isLoadingLibrary = false }
        }
        if registerSystemControls { UserDefaults.standard.set(sourceID, forKey: "Macarok.selectedSource") }
    }

    func waitForLibraryLoad() async { await libraryReloadState?.task?.value }

    func performLibraryWork<Value: Sendable>(_ operation: @escaping @Sendable (LibraryStore) throws -> Value) async throws -> Value {
        guard let store else { throw AppFailure.missingSource }
        return try await backgroundWorker.perform(store: store, operation)
    }

    private func updateQueuedMetadata(from snapshot: LibrarySnapshot) {
        for index in queue.indices {
            if let updated = snapshot.tracksByID[queue[index].track.id], queue[index].track != updated {
                queue[index].track = updated
            }
        }
    }

    private func searchLibrary(reset: Bool) {
        if !reset, searchTask != nil, !search.isEmpty { searchNeedsReload = true; return }
        searchTask?.cancel(); searchTask = nil; searchNeedsReload = false
        searchRequestID = UUID()
        guard let store, let sourceID, !search.isEmpty else { searchCatalog = catalog; isSearching = false; return }
        if reset { searchCatalog = .empty }
        isSearching = true
        let query = search
        let requestID = searchRequestID
        let sources = sources
        searchTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.searchNeedsReload = false
                do {
                    try await Task.sleep(for: .milliseconds(160))
                    let task = Task.detached(priority: .userInitiated) {
                        try LibrarySnapshot.build(sourceID: sourceID,
                                                  tracks: store.tracks(sourceID: sourceID, query: query, ordered: false), sources: sources)
                    }
                    let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                    guard !Task.isCancelled, self.sourceID == sourceID, self.search == query, self.searchRequestID == requestID else { return }
                    self.searchCatalog = result; self.isSearching = false
                } catch is CancellationError { return }
                catch {
                    if self.searchRequestID == requestID { self.fail("Search failed", error.localizedDescription) }
                    break
                }
            } while self.searchNeedsReload
            if self.searchRequestID == requestID { self.searchTask = nil; self.isSearching = false }
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
                        url = try await self.subsonicClient(source).streamURL(songID: remoteID)
                    } else { guard let enclosure = item.track.url else { throw AppFailure.missingFile }; url = enclosure }
                    try Task.checkCancellation()
                    guard self.currentQueueID == id, self.queue.contains(where: { $0.id == id }) else { return }
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
        guard let store else { return }
        queueSaveRevision &+= 1
        let revision = queueSaveRevision
        let ids = queue.map(\.track.id), index = currentIndex ?? 0
        let position = player.position > 0 ? player.position : restorePosition
        Task { try? await backgroundWorker.saveQueue(store: store, trackIDs: ids, currentIndex: index, position: position, revision: revision) }
    }

    func flushQueue() async {
        guard let store else { return }
        queueSaveRevision &+= 1
        try? await backgroundWorker.saveQueue(store: store, trackIDs: queue.map(\.track.id), currentIndex: currentIndex ?? 0,
                                              position: player.position > 0 ? player.position : restorePosition, revision: queueSaveRevision)
    }

    func pickFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Add Music Folder"; panel.message = "Choose a folder to index. Your audio files stay in their current location."
        if panel.runModal() == .OK, let url = panel.url { addFolder(url) }
    }

    func addFolder(_ url: URL) {
        if let existing = sources.first(where: { $0.kind == .local && $0.url?.standardizedFileURL == url.standardizedFileURL }) { sourceID = existing.id; refresh(); return }
        Task {
            do {
                let result = try await performLibraryWork { store in
                    let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    let source = SourceRecord(kind: .local, name: url.lastPathComponent, location: url.absoluteString, bookmarkData: bookmark)
                    try store.saveSource(source)
                    return (source, try store.sources())
                }
                sources = result.1; sourceID = result.0.id; refresh()
            } catch { fail("Could not add the folder", error.localizedDescription) }
        }
    }

    func addServer(name: String, address: String, credentials: SourceCredentials) async throws {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw SourceNetworkError.invalidURL }
        let source = SourceRecord(kind: .openSubsonic, name: name.isEmpty ? (url.host ?? "Music Server") : name, location: url.absoluteString)
        try await Task.detached { try KeychainCredentialStore.shared.save(credentials, sourceID: source.id) }.value
        do {
            let client = OpenSubsonicClient(baseURL: url, credentials: credentials, transport: transport(for: source))
            _ = try await client.ping()
            try await performLibraryWork { try $0.saveSource(source) }
        } catch {
            try? await Task.detached { try KeychainCredentialStore.shared.delete(sourceID: source.id) }.value
            CertificateTrustStore.shared.revoke(sourceID: source.id)
            transportCache.removeValue(forKey: source.id)?.invalidate()
            throw error
        }
        sources = try await performLibraryWork { try $0.sources() }; sourceID = source.id
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
        let savedSource = source
        try await performLibraryWork { try $0.saveSource(savedSource) }
        let artwork = try? await cachePodcastArtwork(feed: feed, source: source)
        let episodes = feed.episodes.map { $0.asTrackRecord(sourceID: savedSource.id, feed: feed, artworkPath: artwork?.path) }
        try await performLibraryWork { try $0.upsertTracks(episodes) }
        sources = try await performLibraryWork { try $0.sources() }; sourceID = source.id
        reloadLibrary(); status = "Subscribed to “\(source.name)”."
    }

    func removeSource(_ source: SourceRecord) {
        Task {
          do {
            if refreshSourceID == source.id { refreshTask?.cancel() }
            if currentTrack?.sourceID == source.id { playbackTask?.cancel(); player.stop(); activeStream?.close(); currentQueueID = nil; restorePosition = 0; updateNowPlaying() }
            queue.removeAll { $0.track.sourceID == source.id }
            guard let store else { throw AppFailure.missingSource }
            try await backgroundWorker.deleteSource(store: store, sourceID: source.id, incompleteKey: Self.catalogImportKey(source.id))
            try await Task.detached { try KeychainCredentialStore.shared.delete(sourceID: source.id) }.value
            CertificateTrustStore.shared.revoke(sourceID: source.id)
            accessedFolders.removeValue(forKey: source.id)?.stopAccessingSecurityScopedResource()
            transportCache.removeValue(forKey: source.id)?.invalidate()
            sources = try await performLibraryWork { try $0.sources() }
            if sourceID == source.id { sourceID = sources.first?.id }
            reloadLibrary(); saveQueue()
          } catch { fail("Could not remove the source", error.localizedDescription) }
        }
    }

    func refresh() {
        guard let source = selectedSource, let store else { return }
        refreshTask?.cancel()
        remoteCatalogProgress?.acceptingBatches = false
        remoteCatalogProgress?.publicationTask?.cancel()
        remoteCatalogProgress = nil
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
                try await self.backgroundWorker.beginRefresh(store: store, sourceID: source.id, generation: generation,
                                                              incompleteKey: source.kind == .openSubsonic ? Self.catalogImportKey(source.id) : nil)
                switch source.kind {
                case .local:
                    let resolved = self.accessFolder(source)
                    var scanSource = source
                    if let resolved { scanSource.location = resolved.absoluteString }
                    let result = try await self.localScan(scanSource, { [weak self] count, total in
                        Task { @MainActor in if self?.refreshGeneration == generation { self?.refreshProgress = "Reading file \(count) of \(total)…" } }
                    })
                    try Task.checkCancellation()
                    if result.isComplete { try await self.backgroundWorker.replace(store: store, sourceID: source.id, generation: generation, tracks: result.tracks) }
                    else { try await self.backgroundWorker.upsert(store: store, sourceID: source.id, generation: generation, tracks: result.tracks) }
                    self.scanWarnings = result.warnings
                case .openSubsonic:
                    try await self.importRemoteCatalog(source: source, store: store, generation: generation)
                case .podcasts:
                    guard let url = source.url else { throw SourceNetworkError.invalidURL }
                    let feed = try await PodcastClient(transport: self.transport(for: source)).fetchFeed(url: url)
                    let artwork = try? await self.cachePodcastArtwork(feed: feed, source: source)
                    try Task.checkCancellation()
                    try await self.backgroundWorker.upsert(store: store, sourceID: source.id, generation: generation,
                                                           tracks: feed.episodes.map { $0.asTrackRecord(sourceID: source.id, feed: feed, artworkPath: artwork?.path) })
                }
                guard self.refreshGeneration == generation else { return }
                if source.kind != .openSubsonic { self.reloadLibrary(); await self.waitForLibraryLoad() }
                self.status = self.scanWarnings.isEmpty ? "“\(source.name)” is up to date." : "Scan completed with \(self.scanWarnings.count) warnings."
            } catch {
                if self.refreshGeneration == generation {
                    if Task.isCancelled || error is CancellationError { self.status = "Refresh cancelled." }
                    else { self.fail("Could not refresh “\(source.name)”", error.localizedDescription) }
                }
            }
        }
    }

    func cancelRefresh() {
        remoteCatalogProgress?.acceptingBatches = false
        refreshTask?.cancel()
    }

    private func importRemoteCatalog(source: SourceRecord, store: LibraryStore, generation: UUID) async throws {
        try Task.checkCancellation()
        guard refreshGeneration == generation, sources.contains(where: { $0.id == source.id }) else { throw CancellationError() }
        let progress = RemoteCatalogProgress()
        remoteCatalogProgress = progress
        defer {
            progress.acceptingBatches = false
            progress.publicationTask?.cancel()
            if remoteCatalogProgress === progress { remoteCatalogProgress = nil }
        }
        let receive: @Sendable ([TrackRecord], Int, Int?) async throws -> Void = { [weak self] batch, completed, total in
            guard let self else { throw CancellationError() }
            try await self.acceptRemoteBatch(batch, completed: completed, total: total, source: source,
                                            store: store, generation: generation, progress: progress)
        }
        do {
            if let remoteCatalog { try await remoteCatalog(source, receive) }
            else {
                let client = try await subsonicClient(source)
                try await client.streamLibrary(sourceID: source.id) { tracks, completed, total in
                    try await receive(tracks.map { $0.asTrackRecord(sourceID: source.id) }, completed, total)
                }
            }
            try Task.checkCancellation()
            guard refreshGeneration == generation, sources.contains(where: { $0.id == source.id }) else { throw CancellationError() }
            if let error = progress.publicationError { throw error }
            progress.acceptingBatches = false
            progress.publicationTask?.cancel()
            try await backgroundWorker.finishCatalog(store: store, sourceID: source.id, generation: generation,
                                                      activeIDs: progress.activeIDs, incompleteKey: Self.catalogImportKey(source.id))
            try await publishRemoteSnapshot(source: source, store: store, generation: generation, progress: progress)
            try Task.checkCancellation()
            guard refreshGeneration == generation else { throw CancellationError() }
        } catch {
            progress.acceptingBatches = false
            progress.publicationTask?.cancel()
            // Preserve and show committed batches even when the remaining import fails or is cancelled.
            try? await publishRemoteSnapshot(source: source, store: store, generation: generation,
                                            progress: progress, allowCancelled: true)
            throw error
        }
    }

    nonisolated private static func catalogImportKey(_ sourceID: String) -> String { "catalogImport.incomplete.\(sourceID)" }

    private func acceptRemoteBatch(_ batch: [TrackRecord], completed: Int, total: Int?, source: SourceRecord,
                                   store: LibraryStore, generation: UUID, progress: RemoteCatalogProgress) async throws {
        try Task.checkCancellation()
        guard refreshGeneration == generation, refreshSourceID == source.id, isRefreshing,
              remoteCatalogProgress === progress, progress.acceptingBatches,
              sources.contains(where: { $0.id == source.id }) else { throw CancellationError() }
        if let error = progress.publicationError { throw error }
        guard batch.allSatisfy({ $0.sourceID == source.id }) else { throw SourceNetworkError.invalidResponse }
        try await backgroundWorker.upsert(store: store, sourceID: source.id, generation: generation, tracks: batch)
        guard refreshGeneration == generation, remoteCatalogProgress === progress, progress.acceptingBatches else { throw CancellationError() }
        progress.activeIDs.formUnion(batch.map(\.id))
        progress.revision &+= 1
        let albumProgress = total.map { "\(completed) of \($0) albums" } ?? "\(completed) albums"
        refreshProgress = "Imported \(albumProgress) · \(progress.activeIDs.count) tracks"
        scheduleRemotePublication(source: source, store: store, generation: generation, progress: progress)
        if progress.lastPublished == nil, let publication = progress.publicationTask {
            await publication.value
            if let error = progress.publicationError { throw error }
        }
        try Task.checkCancellation()
    }

    private func scheduleRemotePublication(source: SourceRecord, store: LibraryStore, generation: UUID,
                                           progress: RemoteCatalogProgress) {
        guard sourceID == source.id, progress.publicationTask == nil, progress.acceptingBatches else { return }
        let deadline = progress.lastPublished?.advanced(by: .milliseconds(750))
        progress.publicationTask = Task { [weak self] in
            guard let self else { return }
            var revision = progress.revision
            do {
                if let deadline { try await Task.sleep(until: deadline, clock: .continuous) }
                try Task.checkCancellation()
                revision = progress.revision
                try await self.publishRemoteSnapshot(source: source, store: store, generation: generation, progress: progress)
            } catch is CancellationError { }
            catch { progress.publicationError = error }
            progress.publicationTask = nil
            if !Task.isCancelled, self.refreshGeneration == generation, progress.revision != revision {
                self.scheduleRemotePublication(source: source, store: store, generation: generation, progress: progress)
            }
        }
    }

    private func publishRemoteSnapshot(source: SourceRecord, store: LibraryStore, generation: UUID,
                                       progress: RemoteCatalogProgress, allowCancelled: Bool = false) async throws {
        guard sourceID == source.id, refreshGeneration == generation,
              sources.contains(where: { $0.id == source.id }) else { return }
        reloadLibrary()
        await waitForLibraryLoad()
        if !allowCancelled { try Task.checkCancellation() }
        guard sourceID == source.id, refreshGeneration == generation,
              sources.contains(where: { $0.id == source.id }) else { return }
        progress.lastPublished = ContinuousClock().now
    }

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
                if stale, let renewed = try? url.bookmarkData(options: .withSecurityScope) {
                    var updated = source; updated.bookmarkData = renewed
                    let renewedSource = updated
                    Task { try? await performLibraryWork { try $0.saveSource(renewedSource) } }
                }
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

    func subsonicClient(_ source: SourceRecord) async throws -> OpenSubsonicClient {
        guard let url = source.url else { throw SourceNetworkError.invalidURL }
        let credentials = try await Task.detached { try KeychainCredentialStore.shared.load(sourceID: source.id) }.value
        try Task.checkCancellation()
        guard let credentials, sources.contains(where: { $0.id == source.id }) else { throw SourceNetworkError.missingCredentials }
        return OpenSubsonicClient(baseURL: url, credentials: credentials, transport: transport(for: source))
    }

    func ensureArtwork(_ track: TrackRecord) async {
        guard track.artworkPath == nil, let cover = track.coverArtID, !artworkTasks.contains(track.albumID), let source = sources.first(where: { $0.id == track.sourceID }), source.kind == .openSubsonic else { return }
        artworkTasks.insert(track.albumID)
        defer { artworkTasks.remove(track.albumID) }
        do {
            let data = try await subsonicClient(source).coverArt(id: cover)
            let url = try await cacheArtwork(data, key: StableID.make(source.id, cover))
            let record = try await performLibraryWork { store in
                try store.cacheRemoteArtwork(sourceID: source.id, albumID: track.albumID, coverArtID: cover, path: url.path)
                return try store.track(id: track.id)
            }
            if let path = record?.artworkPath {
                for index in queue.indices where queue[index].track.albumID == track.albumID && queue[index].track.artworkPath == nil {
                    queue[index].track.artworkPath = path
                }
            }
            if sourceID == source.id { reloadLibrary() }
        } catch { }
    }

    func cacheArtwork(_ data: Data, key: String) async throws -> URL {
        let databaseURL = store.map { URL(fileURLWithPath: $0.database.path) } ?? LibraryStore.defaultURL
        let directory = databaseURL.deletingLastPathComponent().appendingPathComponent("Artwork", isDirectory: true)
        return try await backgroundWorker.cacheArtwork(data, key: key, directory: directory)
    }

    private func cachePodcastArtwork(feed: PodcastFeed, source: SourceRecord) async throws -> URL? {
        guard let url = feed.artworkURL else { return nil }
        let data = try await transport(for: source).data(from: url)
        return try await cacheArtwork(data, key: StableID.make(source.id, "podcast-artwork"))
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

    func rate(_ track: TrackRecord, value: Int) {
        Task {
            do { try await performLibraryWork { try $0.setRating(trackID: track.id, rating: value) }; reloadLibrary() }
            catch { fail("Could not save rating", error.localizedDescription) }
        }
    }

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
                playRecorded = true
                Task {
                    try? await performLibraryWork { try $0.recordPlay(trackID: track.id, at: Date()) }
                    reloadLibrary()
                }
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
