import AppKit
import Combine
import Foundation
import KeyboardShortcuts
import MacarokAudio
import MacarokCore
import MacarokMetadata
import MediaPlayer
import Observation
import os
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
typealias ScopedLibrarySnapshotLoader = @Sendable (LibraryScope, LibraryStore, [SourceRecord]) async throws -> LibrarySnapshot

@MainActor
private final class LibraryReloadState {
    let scope: LibraryScope
    var requestedRevision = 1
    var task: Task<Void, Never>?
    init(scope: LibraryScope) { self.scope = scope }
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
    let playbackDiagnostics = PlaybackDiagnosticsController()
    @ObservationIgnored private var playbackSuspended = false
    @ObservationIgnored private var accountedHandoffUptime: TimeInterval?
    var settings = AppPreferences.load() {
        didSet {
            if registerSystemControls { settings.save() }
            player.volume = settings.volume
            if oldValue.repeatMode != settings.repeatMode || oldValue.buffer != settings.buffer { prepareNextPlayback() }
        }
    }
    var sources: [SourceRecord] = [] {
        didSet {
            guard oldValue != sources else { return }
            sourcesByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            radioSourceIDs = Set(sources.filter { $0.kind == .radio }.map(\.id))
            let removedIDs = Set(oldValue.map(\.id)).subtracting(sources.map(\.id))
            podcastDownloads?.cancel(sourceIDs: removedIDs)
            for source in oldValue where sourcesByID[source.id] != source { invalidateSourceClient(source.id) }
            if !removedIDs.isEmpty {
                presentationPatches.removeAll(); presentationPatchRevision &+= 1
                for id in removedIDs { unpublishedSourceChanges[id] = nil }
                Task { await playbackPreparation.invalidate(sourceIDs: removedIDs) }
            }
            sourceRevision &+= 1
            searchTask?.cancel(); searchTask = nil; searchRequestID = UUID(); searchNeedsReload = false; isSearching = false
            if !Set(oldValue.map(\.id)).subtracting(sources.map(\.id)).isEmpty {
                catalog = .empty; searchCatalog = .empty; libraryRevision &+= 1
                queueUndoManager.removeAllActions()
            }
            if libraryScope != nil { reloadLibrary(); watchSelectedSource() }
        }
    }
    private(set) var sourcesByID: [String: SourceRecord] = [:]
    private(set) var radioSourceIDs: Set<String> = []
    var libraryScope: LibraryScope? {
        didSet {
            guard oldValue != libraryScope else { return }
            if !isEditingContext {
                selectedTrackID = nil; selectedAlbumID = nil; selectedAlbumSourceID = nil; selectedArtist = nil; selectedFolder = nil
            }
            search = ""; reloadLibrary(); watchSelectedSource(); persistLibraryScope()
            followPlaybackContext()
        }
    }
    var sourceID: String? {
        get { libraryScope?.sourceID }
        set { libraryScope = newValue.map(LibraryScope.source) }
    }
    var libraryView: LibraryView = .home { didSet { if libraryView == .home { contextPage = .home } } }
    var contextMode: ContextMode = .context {
        didSet { contextModeDidChange(from: oldValue) }
    }
    var contextPage: ContextPage = .home
    var homeFilter: HomeFilter = .all
    var contextTab = "Overview"
    var metadataEditingSession: MetadataEditingSession? {
        didSet { if oldValue != nil && metadataEditingSession == nil && contextMode == .editMetadata { followPlaybackContext() } }
    }
    var albumMetadataEditingSession: AlbumMetadataEditingSession? {
        didSet { if oldValue != nil && albumMetadataEditingSession == nil && contextMode == .editAlbumMetadata { followPlaybackContext() } }
    }
    var search = "" { didSet { searchLibrary(reset: true) } }
    private var catalog = LibrarySnapshot.empty
    private var searchCatalog = LibrarySnapshot.empty
    var tracks: [TrackRecord] { catalog.tracks }
    private(set) var libraryRevision = 0
    var searchResults: [TrackRecord] { searchCatalog.tracks }
    private(set) var isLoadingLibrary = false
    private(set) var isSearching = false
    var snapshotSourceID: String? { catalog.sourceID }
    var snapshotScope: LibraryScope? { catalog.scope }
    var selectedTrackID: String?
    var selectedAlbumID: String?
    var selectedAlbumSourceID: String?
    var selectedArtist: String?
    var selectedFolder: String?
    var queue: [QueueItem] = [] {
        didSet {
            let sameEntries = queue.count == oldValue.count && zip(queue, oldValue).allSatisfy { $0.id == $1.id && $0.track.id == $1.track.id }
            if !sameEntries {
                queueIndices = Dictionary(queue.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
                queueTrackIDs = queue.map(\.track.id)
                queueRevision &+= 1
                prepareNextPlayback()
            }
            if !sameEntries || zip(queue, oldValue).contains(where: { $0.track.duration != $1.track.duration }) {
                cachedQueueDuration = queue.reduce(0) { $0 + $1.track.duration }
            }
        }
    }
    private(set) var queueRevision = 0
    @ObservationIgnored private var cachedQueueDuration: Double = 0
    @ObservationIgnored private var queueIndices: [UUID: Int] = [:]
    @ObservationIgnored private var queueTrackIDs: [String] = []
    @ObservationIgnored var queueMetadataOverrides: [String: TrackRecord] = [:]
    var currentQueueID: UUID? {
        didSet { if oldValue != currentQueueID { followPlaybackContext(); prepareNextPlayback() } }
    }
    var selectedQueueID: UUID?
    var playlists: [PlaylistRecord] = []
    var isRefreshing = false
    var isStoppingRefresh = false
    var refreshProgress = ""
    var status = "Add a music folder or connect a source to get started."
    var message: AppMessage?
    var addSourcePresenter: AddSourcePresenter? {
        didSet {
            guard oldValue != addSourcePresenter else { return }
            connectionPresentationID = addSourcePresenter == nil ? nil : UUID()
            let pendingIDs = Set(pendingSourceConnections.keys)
            pendingSourceConnections.removeAll()
            rejectCertificatePrompts(sourceIDs: pendingIDs)
            for sourceID in pendingIDs where !sources.contains(where: { $0.id == sourceID }) {
                transportCache.removeValue(forKey: sourceID)?.invalidate()
            }
        }
    }
    var showAddSource: Bool {
        get { addSourcePresenter != nil }
        set { addSourcePresenter = newValue ? .mainWindow : nil }
    }
    func presentAddSource(from presenter: AddSourcePresenter) { addSourcePresenter = presenter }
    var editingTrack: TrackRecord? {
        didSet { if oldValue != nil && editingTrack == nil { followPlaybackContext() } }
    }
    var artworkTrack: TrackRecord? {
        didSet { if oldValue != nil && artworkTrack == nil { followPlaybackContext() } }
    }
    var certificatePrompts: [CertificatePrompt] = []
    var artworkRevision = 0
    var streamingBufferFraction: Double?
    var scanWarnings: [String] = []
    var radio: RadioController?
    var scrobbling: ScrobblingController?
    var podcastDownloads: PodcastDownloadsController?
    var radioBroadcastTitle: String?
    var radioDisconnected = false
    var radioDiscoveryOwnsCertificates = false
    @ObservationIgnored var store: LibraryStore?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = UUID()
    @ObservationIgnored private var refreshSourceID: String?
    @ObservationIgnored private var refreshBatchPosition = 0
    @ObservationIgnored private var refreshBatchCount = 0
    @ObservationIgnored private var pendingRescanSourceIDs: Set<String> = []
    @ObservationIgnored private var pendingRescanCoverage: [String: LocalScanCoverage] = [:]
    @ObservationIgnored private var scheduledRescanCoverage: [String: LocalScanCoverage] = [:]
    @ObservationIgnored private var scheduledArtworkRescans: Set<String> = []
    @ObservationIgnored private var unpublishedSourceChanges: [String: Int] = [:]
    @ObservationIgnored private let localScan: LocalScanOperation?
    @ObservationIgnored private let remoteCatalog: RemoteCatalogOperation?
    @ObservationIgnored private let snapshotLoader: ScopedLibrarySnapshotLoader
    @ObservationIgnored private let selectionDefaults: UserDefaults
    @ObservationIgnored private let savesLibrarySelection: Bool
    @ObservationIgnored private var sourceRevision = 0
    @ObservationIgnored let lyricsResolver = LyricsResolver()
    @ObservationIgnored private let backgroundWorker = LibraryBackgroundWorker()
    @ObservationIgnored private var libraryReloadState: LibraryReloadState?
    @ObservationIgnored private var searchRequestID = UUID()
    @ObservationIgnored private var searchNeedsReload = false
    @ObservationIgnored private var queueSaveRevision = 0
    @ObservationIgnored private var remoteCatalogProgress: RemoteCatalogProgress?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored var playbackTask: Task<Void, Never>?
    @ObservationIgnored var activeStream: BufferedHTTPInputStream?
    @ObservationIgnored var playbackGeneration = UUID()
    @ObservationIgnored var playbackIntentQueueID: UUID?
    @ObservationIgnored private let queueUndoController = QueueUndoController()
    @ObservationIgnored weak var mainPlayerWindow: NSWindow?
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private var menuBarController: MenuBarController?
    @ObservationIgnored private var arrowKeys = PlaybackArrowKeys()
    var queueUndoManager: UndoManager { queueUndoController.manager }
    @ObservationIgnored lazy var queueUndoPresentation = QueueUndoPresentation(model: self)
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var tick: AnyCancellable?
    @ObservationIgnored private var eventSubscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private var transportCache: [String: SourceTransport] = [:]
    @ObservationIgnored private var connectionPresentationID: UUID?
    @ObservationIgnored private var pendingSourceConnections: [String: UUID] = [:]
    @ObservationIgnored private var artworkTasks: Set<String> = []
    @ObservationIgnored private var heardSeconds: Double = 0
    @ObservationIgnored private var playRecorded = false
    @ObservationIgnored var restorePosition: Double = 0
    @ObservationIgnored private var lastSavedTick = 0
    @ObservationIgnored private var directoryWatchers: [String: DirectoryWatcher] = [:]
    @ObservationIgnored private var watcherSetupTask: Task<Void, Never>?
    @ObservationIgnored private var watcherGeneration = UUID()
    @ObservationIgnored private var rescanTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let registerSystemControls: Bool
    @ObservationIgnored private let signposter = OSSignposter(subsystem: "labs.armateur.Macarok", category: "Library")
    @ObservationIgnored private var presentationPatches: [String: LibraryPresentationPatch] = [:]
    @ObservationIgnored private var presentationPatchRevision = 0
    @ObservationIgnored private var presentationPatchTask: Task<Void, Never>?
    @ObservationIgnored private let artworkGate = AsyncOperationGate(limit: 3)
    @ObservationIgnored private var clientCache: [String: OpenSubsonicClient] = [:]
    @ObservationIgnored private var clientRequests: [String: Task<OpenSubsonicClient, Error>] = [:]
    @ObservationIgnored private var clientRevisions: [String: Int] = [:]
    @ObservationIgnored private let playbackPreparation = PlaybackPreparationWorker()
    @ObservationIgnored private var nextPreparation: UpcomingPlaybackPreparation?
    @ObservationIgnored private var activePlaybackResource: PreparedQueuePlayback?

    init(store: LibraryStore? = nil, preferences: AppPreferences? = nil, registerSystemControls: Bool = true,
         localScan: LocalScanOperation? = nil, remoteCatalog: RemoteCatalogOperation? = nil, snapshotLoader: LibrarySnapshotLoader? = nil,
         scopedSnapshotLoader: ScopedLibrarySnapshotLoader? = nil, selectionDefaults: UserDefaults? = nil) {
        self.store = store
        self.registerSystemControls = registerSystemControls
        self.localScan = localScan
        self.remoteCatalog = remoteCatalog
        self.selectionDefaults = selectionDefaults ?? .standard
        self.savesLibrarySelection = registerSystemControls || selectionDefaults != nil
        self.snapshotLoader = scopedSnapshotLoader ?? { scope, store, sources in
            if case .source(let sourceID) = scope, let snapshotLoader {
                return try await snapshotLoader(sourceID, store, sources)
            }
            let task = Task.detached(priority: .utility) {
                try LibrarySnapshot.build(scope: scope,
                                          tracks: store.tracks(scope: scope, ordered: false), sources: sources)
            }
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
        if let preferences { settings = preferences }
    }

    var selectedSource: SourceRecord? { sourceID.flatMap { sourcesByID[$0] } }
    var isAllSources: Bool { libraryScope == .all }
    var scopeTitle: String { isAllSources ? "All Sources" : selectedSource?.name ?? "Your Library" }
    func sourceName(for sourceID: String) -> String { sourcesByID[sourceID]?.name ?? "Unavailable source" }
    func scopeIncludes(sourceID: String) -> Bool { libraryScope?.includes(sourceID: sourceID) == true }
    private func persistLibraryScope() {
        guard savesLibrarySelection else { return }
        if let libraryScope, let data = try? JSONEncoder().encode(libraryScope) {
            selectionDefaults.set(data, forKey: "Macarok.libraryScope")
        } else { selectionDefaults.removeObject(forKey: "Macarok.libraryScope") }
        if let sourceID { selectionDefaults.set(sourceID, forKey: "Macarok.selectedSource") }
    }
    func selectAddedSource(_ id: String) {
        if !isAllSources { libraryScope = .source(id) }
        else { reloadLibrary(); watchSelectedSource() }
    }
    private var displayedCatalog: LibrarySnapshot { search.isEmpty ? catalog : searchCatalog }
    var displayedTracks: [TrackRecord] { displayedCatalog.tracks }
    var albums: [AlbumRecord] { catalog.albums }
    var visibleAlbums: [AlbumRecord] { displayedCatalog.albums }
    var artists: [LibraryArtistGroup] { displayedCatalog.artists }
    var yearGroups: [LibraryYearGroup] { displayedCatalog.yearGroups }
    var genreGroups: [LibraryTrackGroup] { displayedCatalog.genreGroups }
    var formatGroups: [LibraryTrackGroup] { displayedCatalog.formatGroups }
    var folderNodes: [FolderNode] { displayedCatalog.folderNodes }
    func tracksForAlbum(_ album: AlbumRecord) -> [TrackRecord] { catalog.albumsByID[album.presentationID]?.tracks ?? album.tracks }
    func albumsForArtist(_ name: String) -> [AlbumRecord] { catalog.artistsByName[LibraryArtistGroup.normalizedName(name)]?.albums ?? [] }
    func artistSummary(named name: String) -> LibraryArtistGroup? { catalog.artistsByName[LibraryArtistGroup.normalizedName(name)] }
    func cachedTracksInFolder(_ path: String) -> [TrackRecord] {
        displayedCatalog.tracksByFolder[path] ?? []
    }
    var currentIndex: Int? { currentQueueID.flatMap { queueIndices[$0] } }
    var currentTrack: TrackRecord? { currentIndex.flatMap { queue.indices.contains($0) ? queue[$0].track : nil } }
    var currentIsPodcast: Bool { currentTrack.map { sourcesByID[$0.sourceID]?.kind == .podcasts } == true }
    var selectedTrack: TrackRecord? { selectedTrackID.flatMap { id in catalog.tracksByID[id] ?? queue.first { $0.track.id == id }?.track } ?? currentTrack }
    var selectedAlbum: AlbumRecord? {
        if let id = selectedAlbumID, let origin = selectedAlbumSourceID ?? sourceID,
           let album = catalog.albumsByID[StableID.make(origin, "album", id)] { return album }
        return selectedTrack.flatMap { catalog.albumsByID[StableID.make($0.sourceID, "album", $0.albumID)] }
    }
    var queueDuration: Double { _ = queue; return cachedQueueDuration }
    var recentlyAdded: [AlbumRecord] { catalog.recentlyAdded }
    var recentlyPlayed: [TrackRecord] { catalog.recentlyPlayed }
    var mostPlayedTracks: [TrackRecord] { catalog.mostPlayedTracks }
    var mostPlayedAlbums: [AlbumRecord] { catalog.mostPlayedAlbums }
    var mostPlayedArtists: [LibraryArtistGroup] { catalog.mostPlayedArtists }

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
            let dataDirectory = store.map { URL(fileURLWithPath: $0.database.path).deletingLastPathComponent() } ?? LibraryStore.defaultURL.deletingLastPathComponent()
            podcastDownloads = PodcastDownloadsController(model: self, directory: dataDirectory.appendingPathComponent("PodcastDownloads", isDirectory: true))
            await podcastDownloads?.start()
            radio = RadioController(model: self)
            if let store { scrobbling = ScrobblingController(store: store) }
            await radio?.reload()
            if registerSystemControls { await scrobbling?.start() }
            let previous = selectionDefaults.string(forKey: "Macarok.selectedSource")
            let savedScope = savesLibrarySelection ? selectionDefaults.data(forKey: "Macarok.libraryScope").flatMap { try? JSONDecoder().decode(LibraryScope.self, from: $0) } : nil
            if !sources.isEmpty, let savedScope, savedScope == .all || sources.contains(where: { $0.id == savedScope.sourceID }) {
                libraryScope = savedScope
            } else { sourceID = sources.first(where: { $0.id == previous })?.id ?? sources.first?.id }
            playlists = initial.playlists
            if let snapshot = initial.queue {
                let restored = initial.restored.map { (originalIndex: $0.0, item: QueueItem(track: $0.1)) }
                queue = restored.map(\.item)
                if let current = restored.first(where: { $0.originalIndex == snapshot.currentIndex }) {
                    currentQueueID = current.item.id; restorePosition = isRadioTrack(current.item.track) ? 0 : snapshot.position
                } else {
                    currentQueueID = restored.first(where: { $0.originalIndex > snapshot.currentIndex })?.item.id ?? restored.last?.item.id
                }
            }
            player.volume = settings.volume
            player.onCompletion = { [weak self] in
                guard let self else { return }
                self.playbackDiagnostics.record(.completed, occurrenceID: self.playbackGeneration, media: self.playbackMediaKind)
                if self.currentIsRadio { self.radioDisconnected = true; self.playbackIntentQueueID = nil; self.activeStream?.close(); self.activeStream = nil; self.status = "Radio disconnected. Reconnect to listen live." }
                else { self.advance(manual: false) }
            }
            player.onHandoff = { [weak self] id in self?.adoptUpcomingPlayback(id) }
            player.onError = { [weak self] error in
                guard let self else { return }
                self.playbackIntentQueueID = nil
                self.cancelUpcomingPlayback(); self.activeStream?.close(); self.activeStream = nil; self.activePlaybackResource = nil
                self.playbackDiagnostics.record(.failed, occurrenceID: self.playbackGeneration, media: self.playbackMediaKind)
                if self.currentIsRadio { self.radioDisconnected = true; self.activeStream?.close(); self.activeStream = nil; self.status = "Radio disconnected. Reconnect to listen live." }
                else { self.fail("Playback failed", error) }
            }
            player.$state.sink { [weak self] state in
                guard let self else { return }
                // Engine state can publish just before its adoption callback. Keep the old
                // listening occurrence untouched until the native boundary has been accounted for.
                if self.player.handoffTiming.map({ $0.requestedUptime == self.accountedHandoffUptime }) ?? true {
                    self.scrobbling?.update(isPlaying: state == .playing, isBuffering: state == .buffering || self.activeStream?.snapshot.isBuffering == true,
                                            position: self.player.position, duration: self.player.duration)
                }
                if [.paused, .stopped, .failed].contains(state) { self.resetArrowSeek() }
                if state == .paused || state == .failed { self.playbackIntentQueueID = nil }
                self.updateNowPlaying(state: state)
            }.store(in: &eventSubscriptions)
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
                .sink { [weak self] _ in self?.scrobbling?.suspend(); self?.resetArrowSeek(); self?.playbackSuspended = true }.store(in: &eventSubscriptions)
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
                .sink { [weak self] _ in self?.playbackSuspended = false }.store(in: &eventSubscriptions)
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in Task { @MainActor in await self?.podcastDownloads?.start() } }.store(in: &eventSubscriptions)
            if registerSystemControls {
                configureControls()
                menuBarController = MenuBarController(model: self)
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
        guard let store, let scope = libraryScope else {
            libraryReloadState?.task?.cancel(); libraryReloadState = nil
            catalog = .empty; searchCatalog = .empty; libraryRevision &+= 1; isLoadingLibrary = false
            return
        }
        if catalog.scope != scope {
            catalog = .empty; searchCatalog = .empty; libraryRevision &+= 1
        }
        if let state = libraryReloadState, state.scope == scope, state.task != nil {
            state.requestedRevision &+= 1
            return
        }
        libraryReloadState?.task?.cancel()
        let state = LibraryReloadState(scope: scope)
        libraryReloadState = state
        isLoadingLibrary = true
        state.task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let requested = state.requestedRevision
                let sourceRevision = self.sourceRevision
                let registeredSources = self.sources
                let patchRevision = self.presentationPatchRevision
                let dirtyRevisions = self.unpublishedSourceChanges
                do {
                    var snapshot = try await self.snapshotLoader(scope, store, registeredSources)
                    try Task.checkCancellation()
                    guard self.libraryReloadState === state, self.libraryScope == scope else { break }
                    if self.sourceRevision != sourceRevision { continue }
                    snapshot = try await self.overlayPresentationPatches(on: snapshot, after: patchRevision, sources: registeredSources)
                    guard self.libraryReloadState === state, self.libraryScope == scope, self.sourceRevision == sourceRevision else { continue }
                    let interval = self.signposter.beginInterval("PublishSnapshot")
                    self.catalog = snapshot
                    for (id, revision) in dirtyRevisions where scope.includes(sourceID: id) && self.unpublishedSourceChanges[id] == revision {
                        self.unpublishedSourceChanges[id] = nil
                    }
                    self.presentationPatches = self.presentationPatches.filter { $0.value.revision > patchRevision }
                    self.updateQueuedMetadata(from: snapshot)
                    self.libraryRevision &+= 1
                    self.searchLibrary(reset: false)
                    self.signposter.endInterval("PublishSnapshot", interval)
                } catch is CancellationError { break }
                catch {
                    guard self.libraryReloadState === state, self.libraryScope == scope else { break }
                    if self.sourceRevision != sourceRevision { continue }
                    self.fail("Could not read the library", error.localizedDescription)
                    break
                }
                if state.requestedRevision == requested { break }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
            }
            state.task = nil
            if self.libraryReloadState === state { self.isLoadingLibrary = false }
        }
    }

    func waitForLibraryLoad() async { await libraryReloadState?.task?.value; await presentationPatchTask?.value }

    /// Coalesced metadata-only updates do not traverse SQLite or rebuild folder/search ordering.
    func patchLibraryTracks(_ tracks: [TrackRecord], kind: LibraryPatchKind) {
        guard !tracks.isEmpty else { return }
        presentationPatchRevision &+= 1
        for track in tracks {
            var patch = presentationPatches[track.id] ?? LibraryPresentationPatch(revision: presentationPatchRevision)
            patch.merge(track, kind: kind, revision: presentationPatchRevision)
            presentationPatches[track.id] = patch
        }
        let changedIDs = Set(tracks.map(\.id))
        let updatedQueue = queue.map { item -> QueueItem in
            guard changedIDs.contains(item.track.id), let patch = presentationPatches[item.track.id] else { return item }
            var value = item; value.track = patch.applying(to: value.track); return value
        }
        if updatedQueue != queue { queue = updatedQueue }
        for track in tracks {
            if let patch = presentationPatches[track.id] {
                queueMetadataOverrides[track.id] = patch.applying(to: queueMetadataOverrides[track.id] ?? track)
            }
        }
        guard presentationPatchTask == nil else { return }
        presentationPatchTask = Task { [weak self] in
            guard let self else { return }
            defer { self.presentationPatchTask = nil }
            do {
                try await Task.sleep(for: .milliseconds(100))
                while !Task.isCancelled {
                    let revision = self.presentationPatchRevision, baseRevision = self.libraryRevision
                    let scope = self.libraryScope, sourceRevision = self.sourceRevision, sources = self.sources
                    let base = self.catalog, searchBase = self.searchCatalog, query = self.search
                    let patches = self.presentationPatches
                    let work = Task.detached(priority: .utility) {
                        let updates = patches.compactMap { id, patch in base.tracksByID[id].map { patch.applying(to: $0) } }
                        let searchUpdates = patches.compactMap { id, patch in searchBase.tracksByID[id].map { patch.applying(to: $0) } }
                        return try (base.updating(updatedTracks: updates, sources: sources),
                                    searchBase.updating(updatedTracks: searchUpdates, sources: sources))
                    }
                    let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                    guard self.libraryScope == scope, self.sourceRevision == sourceRevision else { continue }
                    if self.libraryRevision != baseRevision { continue }
                    self.catalog = result.0
                    if self.search == query { self.searchCatalog = query.isEmpty ? result.0 : result.1 }
                    self.updateQueuedMetadata(from: result.0); self.libraryRevision &+= 1
                    if revision == self.presentationPatchRevision { break }
                }
            } catch is CancellationError { }
            catch { self.reloadLibrary() }
        }
    }

    private func overlayPresentationPatches(on snapshot: LibrarySnapshot, after revision: Int,
                                             sources: [SourceRecord]) async throws -> LibrarySnapshot {
        while true {
            try Task.checkCancellation()
            let currentRevision = presentationPatchRevision
            let patches = presentationPatches.filter { $0.value.revision > revision }
            guard !patches.isEmpty else { return snapshot }
            let work = Task.detached(priority: .utility) {
                let updates = patches.compactMap { id, patch in snapshot.tracksByID[id].map { patch.applying(to: $0) } }
                return try snapshot.updating(updatedTracks: updates, sources: sources)
            }
            let updated = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            if presentationPatchRevision == currentRevision { return updated }
        }
    }

    func patchRadioStations(_ stations: [TrackRecord]) async {
        guard let scope = libraryScope else { return }
        while libraryScope == scope {
            let base = catalog, revision = libraryRevision, sourceRevision = sourceRevision, sources = sources
            let work = Task.detached(priority: .utility) { try base.updatingStations(stations, sources: sources) }
            guard let updated = try? await work.value, libraryScope == scope, self.sourceRevision == sourceRevision else { return }
            if libraryRevision != revision { continue }
            catalog = updated; if search.isEmpty { searchCatalog = updated }
            updateQueuedMetadata(from: updated); libraryRevision &+= 1
            return
        }
    }

    func performLibraryWork<Value: Sendable>(_ operation: @escaping @Sendable (LibraryStore) throws -> Value) async throws -> Value {
        guard let store else { throw AppFailure.missingSource }
        return try await backgroundWorker.perform(store: store, operation)
    }

    private func updateQueuedMetadata(from snapshot: LibrarySnapshot) {
        for id in queueMetadataOverrides.keys {
            if let updated = snapshot.tracksByID[id] { queueMetadataOverrides[id] = updated }
        }
        var updatedQueue = queue
        var changed = false
        for index in updatedQueue.indices {
            if let updated = snapshot.tracksByID[queue[index].track.id], queue[index].track != updated {
                updatedQueue[index].track = updated; changed = true
            }
        }
        if changed { queue = updatedQueue }
    }

    private func searchLibrary(reset: Bool) {
        if !reset, searchTask != nil, !search.isEmpty { searchNeedsReload = true; return }
        searchTask?.cancel(); searchTask = nil; searchNeedsReload = false
        searchRequestID = UUID()
        guard let store, let scope = libraryScope, !search.isEmpty else { searchCatalog = catalog; isSearching = false; return }
        if reset { searchCatalog = .empty }
        isSearching = true
        let query = search
        let requestID = searchRequestID
        let sources = sources
        let sourceRevision = sourceRevision
        searchTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.searchNeedsReload = false
                do {
                    try await Task.sleep(for: .milliseconds(160))
                    let patchRevision = self.presentationPatchRevision
                    let task = Task.detached(priority: .utility) {
                        try LibrarySnapshot.build(scope: scope,
                                                  tracks: store.tracks(scope: scope, query: query, ordered: false), sources: sources)
                    }
                    var result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                    result = try await self.overlayPresentationPatches(on: result, after: patchRevision, sources: sources)
                    guard !Task.isCancelled, self.libraryScope == scope, self.sourceRevision == sourceRevision, self.search == query, self.searchRequestID == requestID else { return }
                    if self.searchNeedsReload { continue }
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
        selectedTrackID = track.id; selectedAlbumID = track.albumID; selectedAlbumSourceID = track.sourceID; selectedArtist = track.albumArtist
        contextPage = .track
    }

    func inspect(_ album: AlbumRecord) { selectedAlbumID = album.id; selectedAlbumSourceID = album.sourceID; selectedTrackID = album.tracks.first?.id; selectedArtist = album.artist; contextPage = .album }
    func inspectAlbum(containing track: TrackRecord) {
        if !scopeIncludes(sourceID: track.sourceID) { libraryScope = .source(track.sourceID) }
        selectedAlbumID = track.albumID; selectedAlbumSourceID = track.sourceID; selectedTrackID = track.id
        selectedArtist = track.albumArtist; contextPage = .album
    }
    func inspectFolder(_ nodeID: String) { selectedFolder = nodeID; contextPage = .folder }
    var folderTitle: String { selectedFolder.flatMap { catalog.folderTitles[$0] } ?? scopeTitle }
    func inspectArtist(_ name: String) { selectedArtist = name; contextPage = .artist }
    func showCurrentTrack() {
        guard let track = currentTrack else { return }
        if !scopeIncludes(sourceID: track.sourceID) { sourceID = track.sourceID }
        inspect(track)
    }

    private func queueEditState() -> QueueEditState {
        player.synchronizeUpcomingPlayback()
        return QueueEditState(items: queue, currentID: currentQueueID, selectionID: selectedQueueID,
                       resumePosition: player.position > 0 ? player.position : restorePosition)
    }

    private func registerQueueEdit(_ before: QueueEditState, name: String) {
        guard before.items != queue else { return }
        for item in before.items where queueMetadataOverrides[item.track.id] == nil {
            queueMetadataOverrides[item.track.id] = item.track
        }
        queueUndoController.register(model: self, state: before, name: name)
    }

    func restoreQueueEdit(_ state: QueueEditState, name: String) {
        let inverse = queueEditState()
        let liveSession = playbackTask != nil || [.playing, .paused, .opening, .buffering].contains(player.state)
        let current = currentQueueID
        let currentMetadata = Dictionary(queue.map { ($0.track.id, $0.track) }, uniquingKeysWith: { first, _ in first })
        let restored = state.items.map { item -> QueueItem in
            var item = item
            item.track = queueMetadataOverrides[item.track.id] ?? catalog.tracksByID[item.track.id] ?? currentMetadata[item.track.id] ?? item.track
            return item
        }
        let preservePlayback = liveSession && current.map { id in restored.contains { $0.id == id } } == true
        if liveSession && !preservePlayback { stopPlayback(clearCurrent: true) }
        queue = restored
        if !preservePlayback {
            currentQueueID = state.currentID.flatMap { id in restored.contains { $0.id == id } ? id : nil }
            restorePosition = currentQueueID == nil || currentIsRadio ? 0 : state.resumePosition
        }
        selectedQueueID = state.selectionID.flatMap { id in restored.contains { $0.id == id } ? id : nil }
        queueUndoController.register(model: self, state: inverse, name: name)
        saveQueue(); updateNowPlaying()
    }

    func add(_ values: [TrackRecord], play: Bool = false) {
        guard !values.isEmpty else { return }
        let new = values.filter(\.isAvailable).map { QueueItem(track: $0) }
        guard !new.isEmpty else { fail("Tracks unavailable", "The selected files are no longer available. Rescan the source after reconnecting it."); return }
        let before = queueEditState()
        queue.append(contentsOf: new)
        status = new.count == 1 ? "Added “\(new[0].track.title)” to the active playlist." : "Added \(new.count) tracks to the active playlist."
        registerQueueEdit(before, name: "Add to Playlist"); saveQueue()
        if play, let first = new.first { playQueueItem(first.id) }
    }

    func addAfterCurrent(_ values: [TrackRecord]) {
        guard !values.isEmpty else { return }
        let new = values.filter(\.isAvailable).map { QueueItem(track: $0) }
        guard !new.isEmpty else { fail("Tracks unavailable", "The selected files are no longer available. Rescan the source after reconnecting it."); return }
        let before = queueEditState()
        let current = currentIndex
        queue.insert(contentsOf: new, at: current.map { $0 + 1 } ?? queue.endIndex)
        status = current == nil ? "Added \(new.count) tracks to the active playlist." : "Added \(new.count) tracks after the current track."
        registerQueueEdit(before, name: "Add After Current Track"); saveQueue()
    }

    /// Complete artist/album selections always append; an empty queue starts with their first track.
    func doubleClickSelection(_ tracks: [TrackRecord]) { add(tracks, play: queue.isEmpty) }

    func doubleClick(_ track: TrackRecord) {
        if queue.isEmpty { add([track], play: true); return }
        switch settings.trackDoubleClickAction {
        case .append: add([track])
        case .afterCurrent: addAfterCurrent([track])
        case .playNow: add([track], play: true)
        }
    }

    func isReservedArrowShortcut(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        (shortcut.key == .leftArrow || shortcut.key == .rightArrow)
            && shortcut.modifiers.intersection([.command, .option, .control, .shift]).isEmpty
    }

    func resetArrowSeek() { arrowKeys.reset() }

    func seekWithArrow(keyCode: UInt16, isRepeat: Bool) {
        guard player.isSeekable, [123, 124].contains(keyCode) else { resetArrowSeek(); return }
        guard let target = arrowKeys.target(keyCode: keyCode, isRepeat: isRepeat, generation: playbackGeneration,
                                           position: player.position, duration: player.duration) else { return }
        seekPlayback(to: target)
    }

    func seekPlayback(to seconds: Double) {
        player.synchronizeUpcomingPlayback()
        guard !currentIsRadio, player.isSeekable else { return }
        player.seek(to: seconds)
        playbackDiagnostics.markSeek(occurrenceID: playbackGeneration, monotonicTime: ProcessInfo.processInfo.systemUptime)
        scrobbling?.seek(); updateNowPlaying()
    }

    func stopPlayback(clearCurrent: Bool) {
        let unadopted = player.handoffTiming.flatMap { $0.requestedUptime == accountedHandoffUptime ? nil : $0 }
        player.stop() // Stop discards a native handoff without adopting or restarting it.
        scrobbling?.end(discardUnsampledTime: unadopted != nil, atMonotonic: unadopted?.requestedUptime, at: unadopted?.requestedAt)
        cancelUpcomingPlayback()
        playbackGeneration = UUID(); playbackIntentQueueID = nil; resetArrowSeek()
        playbackTask?.cancel(); playbackTask = nil; activeStream?.close(); activeStream = nil
        activePlaybackResource = nil
        player.stop(); restorePosition = 0; streamingBufferFraction = nil
        if clearCurrent { currentQueueID = nil; radioBroadcastTitle = nil; radioDisconnected = false }
    }

    func playQueueItem(_ id: UUID) {
        guard let index = queueIndices[id], queue.indices.contains(index) else { return }
        let item = queue[index]
        if let prepared = nextPreparation, prepared.id == id, prepared.resource != nil,
           sourcesByID[item.track.sourceID] == prepared.source,
           player.playUpcoming(token: id) { return }
        cancelUpcomingPlayback()
        scrobbling?.end(); radioBroadcastTitle = nil; radioDisconnected = false
        let resume = id == currentQueueID ? restorePosition : 0
        restorePosition = 0
        playbackTask?.cancel(); activeStream?.close(); activeStream = nil; activePlaybackResource = nil
        playbackGeneration = UUID(); let generation = playbackGeneration
        playbackIntentQueueID = id; resetArrowSeek()
        player.stop(); currentQueueID = id; heardSeconds = 0; playRecorded = false
        playbackTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.playbackGeneration == generation { self.playbackTask = nil } }
            do {
                try Task.checkCancellation()
                guard self.playbackGeneration == generation, self.currentQueueID == id, self.queue.contains(where: { $0.id == id }) else { return }
                guard let source = self.sourcesByID[item.track.sourceID] else { throw AppFailure.missingSource }
                self.scrobbling?.begin(track: item.track, source: source, occurrenceID: generation)
                if source.kind == .radio {
                    try await self.loadRadio(item: item, source: source, generation: generation)
                } else {
                    let prepared = try await self.preparePlaybackResource(track: item.track, source: source)
                    try Task.checkCancellation()
                    guard self.playbackGeneration == generation, self.currentQueueID == id else { return }
                    self.activePlaybackResource = prepared; self.activeStream = prepared.stream
                    prepared.install(on: self.player, track: item.track, buffer: self.settings.buffer)
                    if let renewed = prepared.renewedSource { Task { try? await self.performLibraryWork { try $0.saveSource(renewed) } } }
                }
                if resume > 0, source.kind != .radio { self.player.seek(to: resume) }
                self.status = "Playing “\(item.track.title)”."
                self.updateNowPlaying(); self.saveQueue()
                self.prepareNextPlayback()
            } catch is CancellationError { }
            catch { if !Task.isCancelled, self.playbackGeneration == generation, self.currentQueueID == id {
                self.playbackIntentQueueID = nil; self.cancelUpcomingPlayback()
                self.playbackDiagnostics.record(.failed, occurrenceID: generation, media: self.playbackMediaKind)
                if self.currentIsRadio { self.radioDisconnected = true }
                self.fail("Could not play the track", error.localizedDescription)
            } }
        }
    }

    private func preparePlaybackResource(track: TrackRecord, source: SourceRecord) async throws -> PreparedQueuePlayback {
        if source.kind == .local {
            let prepared = try await playbackPreparation.prepare(source: source, track: track)
            return PreparedQueuePlayback(url: prepared.url, renewedSource: prepared.renewedSource)
        }
        if source.kind == .podcasts, let downloaded = podcastDownloads?.localURL(for: track),
           await Task.detached(priority: .utility, operation: { FileManager.default.isReadableFile(atPath: downloaded.path) }).value {
            try Task.checkCancellation()
            return PreparedQueuePlayback(url: downloaded)
        }
        let url: URL
        if source.kind == .openSubsonic {
            guard let remoteID = track.remoteID else { throw AppFailure.missingFile }
            url = try await subsonicClient(source).streamURL(songID: remoteID)
        } else { guard let enclosure = track.url else { throw AppFailure.missingFile }; url = enclosure }
        try Task.checkCancellation()
        let isolated = transport(for: source).isolatedPlaybackTransport()
        let stream = BufferedHTTPInputStream(url: url, transport: isolated,
            bufferBytes: Int((settings.buffer ?? 20) * 192_000), bufferSeconds: settings.buffer,
            durationHint: source.kind == .podcasts ? nil : track.duration)
        let prepared = PreparedQueuePlayback(stream: stream, transport: isolated)
        stream.open()
        return prepared
    }

    private func cancelUpcomingPlayback() {
        player.cancelUpcoming()
        if nextPreparation != nil { playbackDiagnostics.record(.upcomingCancelled, occurrenceID: playbackGeneration, media: playbackMediaKind) }
        nextPreparation?.cancel(); nextPreparation = nil
    }

    private func prepareNextPlayback() {
        player.synchronizeUpcomingPlayback()
        let expectedGeneration = playbackGeneration, expectedCurrent = currentQueueID
        guard let index = currentIndex, !queue.isEmpty, !currentIsRadio,
              playbackIntentQueueID != nil || [.playing, .opening, .buffering, .paused].contains(player.state) else {
            cancelUpcomingPlayback(); return
        }
        let nextIndex = settings.repeatMode == .track ? index : index + 1 < queue.count ? index + 1 : settings.repeatMode == .playlist ? 0 : nil
        guard let nextIndex, let source = sourcesByID[queue[nextIndex].track.sourceID], source.kind != .radio else {
            cancelUpcomingPlayback(); return
        }
        let next = queue[nextIndex]
        if let pending = nextPreparation, pending.id == next.id, pending.source == source,
           pending.track == next.track, pending.buffer == settings.buffer,
           pending.task != nil || pending.resource != nil { return }
        cancelUpcomingPlayback()
        guard playbackGeneration == expectedGeneration, currentQueueID == expectedCurrent else {
            prepareNextPlayback(); return
        }
        let pending = UpcomingPlaybackPreparation(id: next.id, source: source, track: next.track, buffer: settings.buffer)
        nextPreparation = pending
        let generation = playbackGeneration
        pending.task = Task(priority: .utility) { [weak self, weak pending] in
            guard let self, let pending else { return }
            defer { pending.task = nil }
            do {
                let resource = try await self.preparePlaybackResource(track: next.track, source: source)
                try Task.checkCancellation()
                guard self.nextPreparation === pending, self.playbackGeneration == generation,
                      self.sourcesByID[source.id] == source else { return }
                pending.resource = resource
                guard resource.installUpcoming(on: self.player, token: next.id, track: next.track, buffer: pending.buffer) else {
                    pending.resource = nil; return
                }
                self.playbackDiagnostics.record(.upcomingPrepared, occurrenceID: generation, media: self.playbackMediaKind)
            } catch { /* Preparation is advisory; normal playback can retry a returning server or file. */ }
        }
    }

    private func adoptUpcomingPlayback(_ id: UUID) {
        guard let pending = nextPreparation, pending.id == id, let resource = pending.resource,
              let index = queueIndices[id], queue.indices.contains(index), sourcesByID[pending.source.id] == pending.source else {
            stopPlayback(clearCurrent: false); return
        }
        let timing = player.handoffTiming
        accountedHandoffUptime = timing?.requestedUptime
        nextPreparation = nil
        scrobbling?.end(discardUnsampledTime: true, atMonotonic: timing?.requestedUptime, at: timing?.requestedAt)
        activeStream = resource.stream; activePlaybackResource = resource
        playbackGeneration = UUID(); playbackIntentQueueID = id; resetArrowSeek()
        currentQueueID = id; restorePosition = 0; heardSeconds = 0; playRecorded = false
        radioBroadcastTitle = nil; radioDisconnected = false
        scrobbling?.begin(track: queue[index].track, source: pending.source, occurrenceID: playbackGeneration,
                          startedAt: timing?.firstPlayingAt)
        scrobbling?.update(isPlaying: player.state == .playing, isBuffering: player.state == .buffering || activeStream?.snapshot.isBuffering == true,
                           position: player.position, duration: player.duration)
        playbackDiagnostics.record(.nativeHandoff, occurrenceID: playbackGeneration, media: playbackMediaKind,
            metrics: .init(position: player.position, transitionSeconds: player.diagnostics.lastTransitionSeconds))
        followPlaybackContext()
        status = "Playing “\(queue[index].track.title)”."
        updateNowPlaying(); saveQueue(); prepareNextPlayback()
    }

    func finishPlaybackAccess() async {
        menuBarController?.stop()
        watcherSetupTask?.cancel(); watcherGeneration = UUID()
        for watcher in directoryWatchers.values { watcher.stop() }
        directoryWatchers.removeAll()
        for task in rescanTasks.values { task.cancel() }; rescanTasks.removeAll()
        cancelUpcomingPlayback()
        await playbackPreparation.shutdown()
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainPlayerWindow, window.isVisible { window.makeKeyAndOrderFront(nil) }
        else { openMainWindow?() }
    }

    func togglePlayback() {
        if [.playing, .opening, .buffering].contains(player.state) || playbackTask != nil {
            pausePlayback(); return
        }
        if currentIsRadio {
            if let id = currentQueueID { playQueueItem(id) }
            return
        }
        if player.state == .stopped || player.state == .failed {
            if let id = currentQueueID ?? queue.first?.id { playQueueItem(id) }
            else if let track = selectedTrack { add([track], play: true) }
        } else { resumePlayback(); updateNowPlaying(); saveQueue() }
    }

    func pausePlayback() {
        player.synchronizeUpcomingPlayback()
        playbackIntentQueueID = nil; resetArrowSeek()
        if currentIsRadio {
            playbackGeneration = UUID(); playbackTask?.cancel(); playbackTask = nil
            activeStream?.close(); activeStream = nil; player.pauseLive(); restorePosition = 0
        } else {
            if playbackTask != nil {
                playbackGeneration = UUID(); playbackTask?.cancel(); playbackTask = nil
                activeStream?.close(); activeStream = nil
            }
            player.pause()
        }
        scrobbling?.suspend()
        updateNowPlaying(); saveQueue()
    }

    func resumePlayback() {
        if currentIsRadio || player.state == .stopped || player.state == .failed {
            if let id = currentQueueID ?? queue.first?.id { playQueueItem(id) }
        } else { player.play() }
    }

    func advance(manual: Bool = true) {
        player.synchronizeUpcomingPlayback()
        guard let index = currentIndex else { if let first = queue.first { playQueueItem(first.id) }; return }
        if !manual && settings.repeatMode == .track { playQueueItem(queue[index].id) }
        else if index + 1 < queue.count { playQueueItem(queue[index + 1].id) }
        else if settings.repeatMode == .playlist, let first = queue.first { playQueueItem(first.id) }
        else { stopPlayback(clearCurrent: false); status = "Playback finished."; saveQueue(); updateNowPlaying() }
    }

    func previous() {
        player.synchronizeUpcomingPlayback()
        if !currentIsRadio, player.position > 3 { seekPlayback(to: 0); return }
        guard let index = currentIndex else { return }
        if index > 0 { playQueueItem(queue[index - 1].id) }
        else if settings.repeatMode == .playlist, let last = queue.last { playQueueItem(last.id) }
        else if !currentIsRadio { seekPlayback(to: 0) }
    }

    func shuffle(_ values: [TrackRecord]) {
        guard !values.isEmpty else { return }
        let available = values.filter(\.isAvailable)
        guard !available.isEmpty else { fail("Tracks unavailable", "Reconnect the source and refresh its library before shuffling these tracks."); return }
        add(available.shuffled(), play: queue.isEmpty)
    }
    func shuffleQueue() {
        let before = queueEditState()
        if let index = currentIndex { let current = queue.remove(at: index); queue.shuffle(); queue.insert(current, at: 0) }
        else { queue.shuffle() }
        registerQueueEdit(before, name: "Shuffle Playlist"); saveQueue()
    }
    func moveQueue(from offsets: IndexSet, to destination: Int) {
        let before = queueEditState()
        queue.move(fromOffsets: offsets, toOffset: destination)
        registerQueueEdit(before, name: "Move Playlist Items"); saveQueue()
    }
    func removeQueue(_ offsets: IndexSet) {
        let before = queueEditState()
        let deletingCurrent = offsets.contains { queue[$0].id == currentQueueID }
        queue.remove(atOffsets: offsets)
        if deletingCurrent { stopPlayback(clearCurrent: true); updateNowPlaying() }
        if let selection = selectedQueueID, !queue.contains(where: { $0.id == selection }) { selectedQueueID = nil }
        registerQueueEdit(before, name: "Remove from Playlist"); saveQueue()
    }
    func clearQueue() {
        let before = queueEditState()
        let active = [.playing, .opening, .buffering].contains(player.state)
            || (playbackTask != nil && playbackIntentQueueID == currentQueueID)
        if active, let current = queue.first(where: { $0.id == currentQueueID }) {
            queue = [current]; selectedQueueID = current.id
        } else {
            stopPlayback(clearCurrent: true)
            queue = []; selectedQueueID = nil; updateNowPlaying()
        }
        registerQueueEdit(before, name: "Clear Playlist"); saveQueue()
    }
    func cycleRepeat() { settings.repeatMode = settings.repeatMode.next }

    func saveQueue() {
        guard let store else { return }
        queueSaveRevision &+= 1
        let revision = queueSaveRevision
        let ids = queueTrackIDs, index = currentIndex ?? 0
        let position = currentIsRadio ? 0 : player.position > 0 ? player.position : restorePosition
        Task { try? await backgroundWorker.saveQueue(store: store, trackIDs: ids, currentIndex: index, position: position, revision: revision) }
    }

    func flushQueue() async {
        guard let store else { return }
        queueSaveRevision &+= 1
        try? await backgroundWorker.saveQueue(store: store, trackIDs: queueTrackIDs, currentIndex: currentIndex ?? 0,
                                              position: currentIsRadio ? 0 : player.position > 0 ? player.position : restorePosition, revision: queueSaveRevision)
    }

    func pickFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Add Music Folder"; panel.message = "Choose a folder to index. Your audio files stay in their current location."
        if panel.runModal() == .OK, let url = panel.url { addFolder(url) }
    }

    func addFolder(_ url: URL) {
        if let existing = sources.first(where: { $0.kind == .local && $0.url?.standardizedFileURL == url.standardizedFileURL }) { selectAddedSource(existing.id); refresh(sourceID: existing.id); return }
        Task {
            do {
                let result = try await performLibraryWork { store in
                    let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    let source = SourceRecord(kind: .local, name: url.lastPathComponent, location: url.absoluteString, bookmarkData: bookmark)
                    try store.saveSource(source)
                    return (source, try store.sources())
                }
                sources = result.1; selectAddedSource(result.0.id); refresh(sourceID: result.0.id)
            } catch { fail("Could not add the folder", error.localizedDescription) }
        }
    }

    func addServer(name: String, address: String, credentials: SourceCredentials) async throws {
        try Task.checkCancellation()
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw SourceNetworkError.invalidURL }
        let source = SourceRecord(kind: .openSubsonic, name: name.isEmpty ? (url.host ?? "Music Server") : name, location: url.absoluteString)
        let connectionStore = store
        let presentationID = beginSourceConnection(sourceID: source.id)
        defer { endSourceConnection(sourceID: source.id) }
        do {
            try await Task.detached { try KeychainCredentialStore.shared.save(credentials, sourceID: source.id) }.value
            try requireSourceConnection(presentationID)
            let client = OpenSubsonicClient(baseURL: url, credentials: credentials, transport: transport(for: source))
            _ = try await client.ping()
            try requireSourceConnection(presentationID)
            let connectedSources = try await performLibraryWork { store in
                try store.saveSource(source, tracks: [])
                return try store.sources()
            }
            try requireSourceConnection(presentationID)
            sources = connectedSources; selectAddedSource(source.id)
            refresh(sourceID: source.id)
        } catch {
            // Cleanup runs independently so cancelling the sheet cannot leave credentials or a hidden source behind.
            await Task.detached {
                try? connectionStore?.deleteSource(id: source.id)
                try? KeychainCredentialStore.shared.delete(sourceID: source.id)
            }.value
            CertificateTrustStore.shared.revoke(sourceID: source.id)
            transportCache.removeValue(forKey: source.id)?.invalidate()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func addPodcast(address: String) async throws {
        try Task.checkCancellation()
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { throw SourceNetworkError.invalidURL }
        if let existing = sources.first(where: { $0.kind == .podcasts && $0.location == url.absoluteString }) { selectAddedSource(existing.id); return }
        let pendingSource = SourceRecord(kind: .podcasts, name: url.host ?? "Podcast", location: url.absoluteString)
        let connectionStore = store
        let presentationID = beginSourceConnection(sourceID: pendingSource.id)
        defer { endSourceConnection(sourceID: pendingSource.id) }
        do {
            let feed = try await PodcastClient(transport: transport(for: pendingSource)).fetchFeed(url: url)
            try requireSourceConnection(presentationID)
            if let existing = sources.first(where: { $0.kind == .podcasts && Self.samePodcastFeed($0.location, feed.url.absoluteString) }) {
                transportCache.removeValue(forKey: pendingSource.id)?.invalidate()
                CertificateTrustStore.shared.revoke(sourceID: pendingSource.id)
                selectAddedSource(existing.id)
                status = "Already subscribed to “\(existing.name)”."
                return
            }
            var source = pendingSource
            source.name = feed.title
            source.location = feed.url.absoluteString
            let artwork = try? await cachePodcastArtwork(feed: feed, source: source)
            try requireSourceConnection(presentationID)
            let savedSource = source
            let connectedSources = try await performLibraryWork { store in
                let episodes = feed.episodes.map { $0.asTrackRecord(sourceID: savedSource.id, feed: feed, artworkPath: artwork?.path) }
                try store.saveSource(savedSource, tracks: episodes)
                return try store.sources()
            }
            try requireSourceConnection(presentationID)
            sources = connectedSources; selectAddedSource(source.id)
            reloadLibrary(); status = "Subscribed to “\(source.name)”."
        } catch {
            await Task.detached { try? connectionStore?.deleteSource(id: pendingSource.id) }.value
            transportCache.removeValue(forKey: pendingSource.id)?.invalidate()
            CertificateTrustStore.shared.revoke(sourceID: pendingSource.id)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    nonisolated static func samePodcastFeed(_ first: String, _ second: String) -> Bool {
        func canonical(_ value: String) -> String? {
            guard var components = URLComponents(string: value) else { return nil }
            components.fragment = nil
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) { components.port = nil }
            if components.path.isEmpty { components.path = "/" }
            return components.string
        }
        return canonical(first) == canonical(second)
    }

    func removeSource(_ source: SourceRecord) {
        Task {
          do {
            queueUndoManager.removeAllActions()
            queueMetadataOverrides = queueMetadataOverrides.filter { $0.value.sourceID != source.id }
            if currentTrack?.sourceID == source.id { stopPlayback(clearCurrent: true); updateNowPlaying() }
            queue.removeAll { $0.track.sourceID == source.id }
            guard let store else { throw AppFailure.missingSource }
            try await backgroundWorker.deleteSource(store: store, sourceID: source.id, incompleteKey: Self.catalogImportKey(source.id))
            try await Task.detached { try KeychainCredentialStore.shared.delete(sourceID: source.id) }.value
            CertificateTrustStore.shared.revoke(sourceID: source.id)
            await playbackPreparation.invalidate(sourceIDs: [source.id])
            transportCache.removeValue(forKey: source.id)?.invalidate()
            sources = try await performLibraryWork { try $0.sources() }
            if sourceID == source.id { sourceID = sources.first?.id }
            reloadLibrary(); saveQueue()
          } catch { fail("Could not remove the source", error.localizedDescription) }
        }
    }

    func refresh() {
        guard let libraryScope else { return }
        startRefresh(sources: sources.filter { libraryScope.includes(sourceID: $0.id) })
    }

    /// A newly connected source and a folder watcher can refresh their own origin without changing browsing scope.
    func refresh(sourceID: String) {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return }
        startRefresh(sources: [source])
    }

    private func startRefresh(sources requestedSources: [SourceRecord], coverages: [String: LocalScanCoverage] = [:]) {
        guard let store, !requestedSources.isEmpty else { return }
        refreshTask?.cancel()
        remoteCatalogProgress?.acceptingBatches = false
        remoteCatalogProgress?.publicationTask?.cancel()
        remoteCatalogProgress = nil
        let generation = UUID()
        refreshGeneration = generation
        refreshBatchCount = requestedSources.count
        refreshBatchPosition = 0
        isRefreshing = true; isStoppingRefresh = false; refreshProgress = "Connecting…"; scanWarnings = []
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.unpublishedSourceChanges.keys.contains(where: { self.scopeIncludes(sourceID: $0) }) { self.reloadLibrary() }
                if self.refreshGeneration == generation {
                    self.isRefreshing = false; self.isStoppingRefresh = false
                    if Task.isCancelled { self.status = "Refresh cancelled." }
                    if Task.isCancelled { self.watchSelectedSource() }
                    self.refreshSourceID = nil
                    let pending = self.sources.filter { self.pendingRescanSourceIDs.contains($0.id) && self.scopeIncludes(sourceID: $0.id) }
                    let pendingCoverage = self.pendingRescanCoverage
                    self.pendingRescanSourceIDs.removeAll(); self.pendingRescanCoverage.removeAll()
                    if !pending.isEmpty { self.startRefresh(sources: pending, coverages: pendingCoverage) }
                }
            }
            var failures: [String] = []
            var completed = 0
            for (index, source) in requestedSources.enumerated() {
                guard self.refreshGeneration == generation, !Task.isCancelled else { break }
                guard self.sources.contains(where: { $0.id == source.id }) else { continue }
                self.refreshSourceID = source.id
                self.refreshBatchPosition = index + 1
                self.refreshProgress = self.refreshLabel("Connecting…")
                do {
                    let changed = try await self.refreshSource(source, store: store, generation: generation,
                        coverage: coverages[source.id] ?? .all)
                    guard self.refreshGeneration == generation else { return }
                    completed += 1
                    if changed || self.unpublishedSourceChanges[source.id] != nil,
                       self.scopeIncludes(sourceID: source.id), source.kind != .openSubsonic {
                        self.reloadLibrary(); await self.waitForLibraryLoad()
                    }
                    self.status = requestedSources.count == 1
                        ? (self.scanWarnings.isEmpty ? "“\(source.name)” is up to date." : "Scan completed with \(self.scanWarnings.count) warnings.")
                        : "Refreshed \(completed) of \(requestedSources.count) sources."
                } catch {
                    guard self.refreshGeneration == generation else { return }
                    if Task.isCancelled { self.status = "Refresh cancelled."; break }
                    // Deleting an origin invalidates its current operation without aborting the other sources.
                    if !self.sources.contains(where: { $0.id == source.id }) { continue }
                    if error is CancellationError { self.status = "Refresh cancelled."; break }
                    failures.append("“\(source.name)”: \(error.localizedDescription)")
                }
            }
            guard self.refreshGeneration == generation, !Task.isCancelled else { return }
            if !failures.isEmpty {
                self.fail(requestedSources.count == 1 ? "Could not refresh “\(requestedSources[0].name)”" : "Some sources could not be refreshed", failures.joined(separator: "\n"))
            } else if requestedSources.count > 1 {
                self.status = "All sources are up to date."
            }
        }
    }

    private func refreshLabel(_ text: String) -> String {
        guard refreshBatchCount > 1, let refreshSourceID else { return text }
        return "\(sourceName(for: refreshSourceID)) (\(refreshBatchPosition)/\(refreshBatchCount)) · \(text)"
    }

    private func refreshSource(_ source: SourceRecord, store: LibraryStore, generation: UUID,
                               coverage: LocalScanCoverage = .all) async throws -> Bool {
        try await backgroundWorker.beginRefresh(store: store, sourceID: source.id, generation: generation,
                                                incompleteKey: source.kind == .openSubsonic ? Self.catalogImportKey(source.id) : nil)
        switch source.kind {
        case .radio:
            let worker = backgroundWorker
            try await radio?.refreshFavorites { station in
                try await worker.updateRadioStation(store: store, station: station, generation: generation)
            }
            return false // RadioController already publishes its separate station patch.
        case .local:
            let resolved = await accessFolder(source)
            var scanSource = source
            if let resolved { scanSource.location = resolved.absoluteString }
            let progress: @Sendable (Int, Int) -> Void = { [weak self] count, total in
                Task { @MainActor in
                    guard let self, !self.isStoppingRefresh, self.refreshGeneration == generation, self.refreshSourceID == source.id else { return }
                    self.refreshProgress = self.refreshLabel("Reading file \(count) of \(total)…")
                }
            }
            let result: LibraryScanResult
            if let localScan { result = try await localScan(scanSource, progress) }
            else {
                let rootURL = scanSource.url
                let read = Task.detached(priority: .background) {
                    let expanded = try store.localScanCoverage(sourceID: source.id, requested: coverage, rootURL: rootURL)
                    return (expanded, try store.localScanCache(sourceID: source.id, coverage: expanded, rootURL: rootURL))
                }
                let (expanded, cache) = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
                result = try await LibraryScanner().scan(source: scanSource, cachedFiles: cache, coverage: expanded,
                    metadataReader: { try TagLibMetadataService.read(url: $0) }, progress: progress)
            }
            try Task.checkCancellation()
            let changed: Bool
            if result.isComplete {
                changed = try await backgroundWorker.replace(store: store, sourceID: source.id, generation: generation,
                    tracks: result.tracks, coverage: result.coverage, rootURL: scanSource.url)
            } else { changed = try await backgroundWorker.upsert(store: store, sourceID: source.id, generation: generation, tracks: result.tracks) }
            if changed { unpublishedSourceChanges[source.id, default: 0] &+= 1 }
            if localScan == nil {
                try await backgroundWorker.saveScanCache(store: store, sourceID: source.id, generation: generation,
                    entries: result.fileCacheEntries, isComplete: result.isComplete, coverage: result.coverage, rootURL: scanSource.url)
            }
            scanWarnings.append(contentsOf: result.warnings)
            return changed
        case .openSubsonic:
            try await importRemoteCatalog(source: source, store: store, generation: generation)
            return false // Its progressive publisher owns catalog publication.
        case .podcasts:
            guard let url = source.url else { throw SourceNetworkError.invalidURL }
            let feed = try await PodcastClient(transport: transport(for: source)).fetchFeed(url: url)
            let artwork = try? await cachePodcastArtwork(feed: feed, source: source)
            try Task.checkCancellation()
            let changed = try await backgroundWorker.upsert(store: store, sourceID: source.id, generation: generation,
                tracks: feed.episodes.map { $0.asTrackRecord(sourceID: source.id, feed: feed, artworkPath: artwork?.path) })
            if changed { unpublishedSourceChanges[source.id, default: 0] &+= 1 }
            return changed
        }
    }

    func toggleRefresh() { if isRefreshing { cancelRefresh() } else { refresh() } }

    func cancelRefresh() {
        guard isRefreshing else { return }
        isStoppingRefresh = true; refreshProgress = "Stopping…"
        // Invalidate even callbacks still queued by the old FSEvents stream. Fresh watchers are
        // installed from SinceNow when cancellation finishes, so future edits remain observable.
        watcherSetupTask?.cancel(); watcherGeneration = UUID()
        for watcher in directoryWatchers.values { watcher.stop() }; directoryWatchers.removeAll()
        pendingRescanSourceIDs.removeAll(); pendingRescanCoverage.removeAll(); scheduledRescanCoverage.removeAll(); scheduledArtworkRescans.removeAll()
        for task in rescanTasks.values { task.cancel() }
        rescanTasks.removeAll()
        remoteCatalogProgress?.acceptingBatches = false
        remoteCatalogProgress?.publicationTask?.cancel()
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
        refreshProgress = refreshLabel("Imported \(albumProgress) · \(progress.activeIDs.count) tracks")
        scheduleRemotePublication(source: source, store: store, generation: generation, progress: progress)
        if progress.lastPublished == nil, let publication = progress.publicationTask {
            await publication.value
            if let error = progress.publicationError { throw error }
        }
        try Task.checkCancellation()
    }

    private func scheduleRemotePublication(source: SourceRecord, store: LibraryStore, generation: UUID,
                                           progress: RemoteCatalogProgress) {
        guard scopeIncludes(sourceID: source.id), progress.publicationTask == nil, progress.acceptingBatches else { return }
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
        guard scopeIncludes(sourceID: source.id), refreshGeneration == generation,
              sources.contains(where: { $0.id == source.id }) else { return }
        reloadLibrary()
        await waitForLibraryLoad()
        if !allowCancelled { try Task.checkCancellation() }
        guard scopeIncludes(sourceID: source.id), refreshGeneration == generation,
              sources.contains(where: { $0.id == source.id }) else { return }
        progress.lastPublished = ContinuousClock().now
    }

    private func watchSelectedSource() {
        watcherSetupTask?.cancel()
        watcherGeneration = UUID()
        let generation = watcherGeneration
        for watcher in directoryWatchers.values { watcher.stop() }
        directoryWatchers.removeAll()
        for task in rescanTasks.values { task.cancel() }
        rescanTasks.removeAll(); scheduledRescanCoverage.removeAll(); scheduledArtworkRescans.removeAll()
        let visibleLocal = sources.filter { $0.kind == .local && scopeIncludes(sourceID: $0.id) }
        pendingRescanSourceIDs.formIntersection(visibleLocal.map(\.id))
        pendingRescanCoverage = pendingRescanCoverage.filter { pendingRescanSourceIDs.contains($0.key) }
        guard registerSystemControls else { return }
        watcherSetupTask = Task { [weak self] in
            guard let self else { return }
            for source in visibleLocal {
                guard !Task.isCancelled, self.watcherGeneration == generation,
                      let url = await self.accessFolder(source), !Task.isCancelled,
                      self.watcherGeneration == generation, self.scopeIncludes(sourceID: source.id) else { continue }
                let watchedURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
                self.directoryWatchers[source.id] = DirectoryWatcher(url: watchedURL) { [weak self] batch in
                    guard LocalFileChangeSuppression.shared.shouldRescan(batch),
                          let coverage = batch.scanCoverage(root: watchedURL) else { return }
                    Task { @MainActor in
                        guard let self, !self.isStoppingRefresh, self.watcherGeneration == generation,
                              self.scopeIncludes(sourceID: source.id), self.sourcesByID[source.id] != nil else { return }
                        if batch.paths.contains(where: { ["jpg", "jpeg", "png", "webp", "gif", "tiff", "heic"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) {
                            self.scheduledArtworkRescans.insert(source.id)
                        }
                        self.scheduledRescanCoverage[source.id] = self.scheduledRescanCoverage[source.id].map { $0.merged(with: coverage) } ?? coverage
                        self.rescanTasks[source.id]?.cancel()
                        self.rescanTasks[source.id] = Task { [weak self] in
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled, let self else { return }
                            self.rescanTasks[source.id] = nil
                            let pending = self.scheduledRescanCoverage.removeValue(forKey: source.id) ?? .all
                            if self.scheduledArtworkRescans.remove(source.id) != nil { self.artworkRevision &+= 1 }
                            self.requestRescan(sourceID: source.id, coverage: pending)
                        }
                    }
                }
            }
        }
    }

    func requestRescan(sourceID: String, coverage: LocalScanCoverage = .all) {
        guard scopeIncludes(sourceID: sourceID), sources.contains(where: { $0.id == sourceID && $0.kind == .local }) else { return }
        guard !isStoppingRefresh else { return }
        if isRefreshing {
            if pendingRescanSourceIDs.contains(sourceID) {
                pendingRescanCoverage[sourceID] = (pendingRescanCoverage[sourceID] ?? .all).merged(with: coverage)
            } else { pendingRescanSourceIDs.insert(sourceID); pendingRescanCoverage[sourceID] = coverage }
        } else if let source = sourcesByID[sourceID] { startRefresh(sources: [source], coverages: [sourceID: coverage]) }
    }

    @discardableResult func accessFolder(_ source: SourceRecord) async -> URL? {
        guard let prepared = try? await playbackPreparation.resolveSource(source), !Task.isCancelled,
              sourcesByID[source.id] == source else { return nil }
        if let renewed = prepared.renewedSource {
            Task { try? await performLibraryWork { try $0.saveSource(renewed) } }
        }
        return prepared.url
    }

    func transport(for source: SourceRecord) -> SourceTransport {
        if let existing = transportCache[source.id] { return existing }
        let value = SourceTransport(sourceID: source.id, certificateApproval: { [weak self] challenge in
            guard let self else { return false }
            return await self.approveCertificate(challenge)
        })
        transportCache[source.id] = value
        return value
    }

    /// Only the current source dialog may request trust for a source that has not been saved yet.
    @discardableResult func beginSourceConnection(sourceID: String) -> UUID? {
        guard let presentationID = connectionPresentationID else { return nil }
        pendingSourceConnections[sourceID] = presentationID
        return presentationID
    }

    private func requireSourceConnection(_ presentationID: UUID?) throws {
        try Task.checkCancellation()
        if let presentationID, presentationID != connectionPresentationID { throw CancellationError() }
    }

    private func endSourceConnection(sourceID: String) {
        pendingSourceConnections.removeValue(forKey: sourceID)
        rejectCertificatePrompts(sourceIDs: [sourceID])
    }

    private func canApproveCertificate(sourceID: String) -> Bool {
        if sources.contains(where: { $0.id == sourceID }) { return true }
        guard addSourcePresenter != nil, let presentationID = connectionPresentationID else { return false }
        return pendingSourceConnections[sourceID] == presentationID
    }

    private func rejectCertificatePrompts(sourceIDs: Set<String>) {
        let rejected = certificatePrompts.filter { sourceIDs.contains($0.challenge.sourceID) }
        certificatePrompts.removeAll { sourceIDs.contains($0.challenge.sourceID) }
        for prompt in rejected { prompt.completion(false) }
    }

    func approveCertificate(_ challenge: ServerCertificateChallenge) async -> Bool {
        guard !Task.isCancelled, canApproveCertificate(sourceID: challenge.sourceID) else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, canApproveCertificate(sourceID: challenge.sourceID) else { continuation.resume(returning: false); return }
                certificatePrompts.append(CertificatePrompt(challenge: challenge, completion: { continuation.resume(returning: $0) }))
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, let index = self.certificatePrompts.firstIndex(where: { $0.id == challenge.id }) else { return }
                self.certificatePrompts.remove(at: index).completion(false)
            }
        }
    }

    func answerCertificate(_ accepted: Bool) {
        guard !certificatePrompts.isEmpty else { return }
        let prompt = certificatePrompts.removeFirst()
        prompt.completion(accepted && canApproveCertificate(sourceID: prompt.challenge.sourceID))
    }

    func subsonicClient(_ source: SourceRecord) async throws -> OpenSubsonicClient {
        if let client = clientCache[source.id] { return client }
        if let request = clientRequests[source.id] {
            let revision = clientRevisions[source.id, default: 0]
            let client = try await request.value
            try Task.checkCancellation()
            guard clientRevisions[source.id, default: 0] == revision, sourcesByID[source.id] == source else { throw CancellationError() }
            return client
        }
        guard let url = source.url else { throw SourceNetworkError.invalidURL }
        let revision = clientRevisions[source.id, default: 0], transport = transport(for: source)
        let request = Task { @MainActor [weak self] in
            let credentials = try await Task.detached(priority: .utility) { try KeychainCredentialStore.shared.load(sourceID: source.id) }.value
            try Task.checkCancellation()
            guard let self, self.sourcesByID[source.id] == source, let credentials else { throw SourceNetworkError.missingCredentials }
            return OpenSubsonicClient(baseURL: url, credentials: credentials, transport: transport)
        }
        clientRequests[source.id] = request
        defer { if clientRevisions[source.id, default: 0] == revision { clientRequests[source.id] = nil } }
        let client = try await request.value
        guard clientRevisions[source.id, default: 0] == revision else { throw CancellationError() }
        clientCache[source.id] = client
        return client
    }

    func invalidateSourceClient(_ id: String) {
        let refreshUpcoming = nextPreparation?.source.id == id
        if refreshUpcoming { cancelUpcomingPlayback() }
        clientRevisions[id, default: 0] &+= 1
        clientCache[id] = nil; clientRequests.removeValue(forKey: id)?.cancel()
        if refreshUpcoming { prepareNextPlayback() }
    }

    func ensureArtwork(_ track: TrackRecord) async {
        let albumKey = StableID.make(track.sourceID, "album", track.albumID)
        guard track.artworkPath == nil, let cover = track.coverArtID, !artworkTasks.contains(albumKey), let source = sourcesByID[track.sourceID], source.kind == .openSubsonic else { return }
        artworkTasks.insert(albumKey)
        defer { artworkTasks.remove(albumKey) }
        do {
            let client = try await subsonicClient(source)
            let data = try await artworkGate.withPermit { try await client.coverArt(id: cover) }
            try Task.checkCancellation()
            guard sourcesByID[source.id] == source else { return }
            let url = try await cacheArtwork(data, key: StableID.make(source.id, cover))
            let record = try await performLibraryWork { store in
                try store.cacheRemoteArtwork(sourceID: source.id, albumID: track.albumID, coverArtID: cover, path: url.path)
                return try store.albumTracks(sourceID: source.id, albumID: track.albumID)
            }
            patchLibraryTracks(record, kind: .artwork)
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

    func rate(_ track: TrackRecord, value: Int) {
        Task {
            do {
                let updated = try await performLibraryWork { store in try store.setRating(trackID: track.id, rating: value); return try store.track(id: track.id) }
                if let updated { patchLibraryTracks([updated], kind: .rating) }
            }
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

    private var playbackMediaKind: PlaybackEventLog.MediaKind {
        guard let track = currentTrack, let kind = sourcesByID[track.sourceID]?.kind else { return .unknown }
        switch kind {
        case .local: return .localFile
        case .openSubsonic: return .remoteMusic
        case .podcasts: return .podcast
        case .radio: return .radio
        }
    }

    private func checkPlaybackHealth() {
        let health = player.healthSnapshot // Reconciles a handoff before sampling its queue occurrence.
        let stream = activeStream?.snapshot
        let phase: PlaybackWatchdog.Phase = playbackTask != nil ? .preparing
            : player.state == .playing && stream?.isBuffering == true ? .buffering
            : PlaybackWatchdog.Phase(rawValue: player.state.rawValue) ?? .stopped
        let output = health.playedAudioBuffers.flatMap { $0 > 0 ? $0 : nil }
        let sample = PlaybackWatchdog.Sample(occurrenceID: currentQueueID == nil ? nil : playbackGeneration,
            monotonicTime: ProcessInfo.processInfo.systemUptime, phase: phase,
            position: currentIsRadio ? nil : health.position, isLive: currentIsRadio,
            isSuspended: playbackSuspended, audioOutputCounter: output,
            transportProgressCounter: stream?.retainedRanges.last?.upperBound, expectedBufferSeconds: settings.buffer)
        guard let incident = playbackDiagnostics.observe(sample, engine: player.diagnostics, stream: stream,
            media: playbackMediaKind, health: health, duration: player.duration),
            incident.occurrenceID == playbackGeneration else { return }
        cancelUpcomingPlayback()
        guard incident.occurrenceID == playbackGeneration else { return }
        playbackTask?.cancel(); playbackTask = nil; playbackIntentQueueID = nil
        activeStream?.close(); activeStream = nil; activePlaybackResource = nil
        scrobbling?.suspend(); resetArrowSeek()
        player.failStalledPlayback(currentIsRadio
            ? "The radio stopped making progress. Reconnect to listen live."
            : "Playback stopped making progress. Press Play to retry, or choose another track.")
    }

    private func playbackTick() {
        player.synchronizeUpcomingPlayback()
        checkPlaybackHealth()
        let bufferFraction: Double?
        if let snapshot = activeStream?.snapshot, snapshot.isBuffering {
            bufferFraction = min(1, Double(snapshot.bufferedBytes) / Double(max(1, snapshot.targetBytes)))
        } else { bufferFraction = nil }
        if streamingBufferFraction != bufferFraction { streamingBufferFraction = bufferFraction }
        scrobbling?.update(isPlaying: player.state == .playing, isBuffering: player.state == .buffering || streamingBufferFraction != nil,
                           position: player.position, duration: player.duration)
        if player.state == .playing, !currentIsRadio, let track = currentTrack {
            heardSeconds += 1
            let duration = player.duration > 0 ? player.duration : track.duration
            let threshold = min(240, max(1, duration > 0 ? duration / 2 : 240))
            if !playRecorded && heardSeconds >= threshold {
                playRecorded = true
                Task {
                    let updated = try? await performLibraryWork { store in try store.recordPlay(trackID: track.id, at: Date()); return try store.track(id: track.id) }
                    if let updated { patchLibraryTracks([updated], kind: .history) }
                }
            }
        }
        lastSavedTick += 1
        if lastSavedTick >= 5 {
            lastSavedTick = 0; updateNowPlaying()
            if player.state == .playing, let store {
                queueSaveRevision &+= 1
                let revision = queueSaveRevision, index = currentIndex ?? 0, position = currentIsRadio ? 0 : player.position
                Task { try? await backgroundWorker.saveQueuePosition(store: store, currentIndex: index, position: position, revision: revision) }
            }
        }
    }

    private func configureControls() {
        let commands = MPRemoteCommandCenter.shared()
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlayback() }; return .success }
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in
            guard let self else { return }
            self.resumePlayback()
        }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pausePlayback() }; return .success }
        commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.advance() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seekPlayback(to: event.positionTime) }; return .success
        }
        KeyboardShortcuts.onKeyUp(for: .playPause) { [weak self] in self?.togglePlayback() }
        KeyboardShortcuts.onKeyUp(for: .nextTrack) { [weak self] in self?.advance() }
        KeyboardShortcuts.onKeyUp(for: .previousTrack) { [weak self] in self?.previous() }
        KeyboardShortcuts.onKeyUp(for: .showMacarok) { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first?.makeKeyAndOrderFront(nil) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp], handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyUp {
                if [123, 124].contains(event.keyCode) { self.resetArrowSeek() }
                return event
            }
            if PlaybackArrowKeys.isReserved(keyCode: event.keyCode, modifiers: event.modifierFlags) {
                guard PlaybackArrowKeys.accepts(window: event.window, mainWindow: self.mainPlayerWindow) else { self.resetArrowSeek(); return event }
                guard self.player.isSeekable else { return event }
                self.seekWithArrow(keyCode: event.keyCode, isRepeat: event.isARepeat)
                return nil
            }
            guard !event.isARepeat, NSApp.keyWindow === self.mainPlayerWindow,
                  NSApp.keyWindow?.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
            let editing = NSApp.keyWindow?.firstResponder is NSTextView || PlaybackArrowKeys.webView(for: NSApp.keyWindow?.firstResponder) != nil
            if !editing, let shortcut = KeyboardShortcuts.Shortcut(event: event) {
                for name in ["playPause", "previousTrack", "nextTrack", "addToPlaylist", "search", "showCurrentTrack"] where self.localShortcut(name) == shortcut {
                    self.performLocalShortcut(name)
                    return nil
                }
            }
            return event
        }) { monitors.append(monitor) }
    }

    private func updateNowPlaying(state: PlaybackState? = nil) {
        let playbackState = state ?? player.state
        guard let track = currentTrack else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        if currentIsRadio {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: track.title,
                MPMediaItemPropertyArtist: radioBroadcastTitle ?? "Internet Radio", MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyPlaybackRate: playbackState == .playing ? 1.0 : 0.0]
            MPNowPlayingInfoCenter.default().playbackState = playbackState == .playing ? .playing : playbackState == .paused ? .paused : .stopped
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artist, MPMediaItemPropertyAlbumTitle: track.album, MPMediaItemPropertyPlaybackDuration: player.duration > 0 ? player.duration : track.duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: player.position, MPNowPlayingInfoPropertyPlaybackRate: playbackState == .playing ? 1.0 : 0.0]
        MPNowPlayingInfoCenter.default().playbackState = playbackState == .playing ? .playing : playbackState == .paused ? .paused : .stopped
    }
}

enum AppFailure: LocalizedError {
    case missingSource, missingFile, invalidArtwork, unsupportedRadio
    var errorDescription: String? {
        switch self {
        case .unsupportedRadio: "Radio playback is being configured."
        case .missingSource: "This track's source is no longer configured."
        case .missingFile: "The audio file is unavailable. Reconnect the source and refresh its library."
        case .invalidArtwork: "The selected image could not be read."
        }
    }
}
