import Foundation
import Observation
import MacarokCore
import MacarokMetadata

enum LyricsViewState: Equatable { case idle, loading, loaded, notFound, instrumental, failed }

struct LyricsDisplayLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
}

struct LyricsSearchItem: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let plainText: String
}

/// Keeps lyrics tied to their actual track, independently of the browsing scope.
@MainActor @Observable
final class LyricsController {
    typealias LocalReader = @Sendable (TrackRecord) async throws -> LyricsDocument?
    typealias FileWriter = @Sendable (LyricsDocument, TrackRecord) async throws -> [URL]
    private weak var model: AppModel?
    @ObservationIgnored private let resolver: LyricsResolver
    @ObservationIgnored private let localReader: LocalReader
    @ObservationIgnored private let fileWriter: FileWriter
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<[LyricsCandidate], Error>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var searchID = UUID()
    @ObservationIgnored private var document: LyricsDocument?
    @ObservationIgnored private var sheetTrack: TrackRecord?
    @ObservationIgnored private var candidates: [String: LyricsCandidate] = [:]

    private(set) var track: TrackRecord?
    private(set) var state: LyricsViewState = .idle
    private(set) var errorTitle = "Unable to Load Lyrics"
    private(set) var errorMessage: String?
    private(set) var sourceLabel = ""
    private(set) var plainText = ""
    private(set) var displayLines: [LyricsDisplayLine] = []
    private(set) var isSavingToFiles = false
    var notice: String?
    var showsSearch = false {
        didSet { if !showsSearch { searchTask?.cancel(); searchTask = nil; searchID = UUID(); isSearching = false } }
    }
    var showsEditor = false
    var searchTitle = ""
    var searchArtist = ""
    var searchAlbum = ""
    private(set) var searchResults: [LyricsSearchItem] = []
    private(set) var isSearching = false
    private(set) var searchError: String?
    var editedText = ""
    private(set) var editorError: String?
    private(set) var isSavingEdit = false

    init(model: AppModel, resolver: LyricsResolver? = nil,
         localReader: @escaping LocalReader = { track in
             let work = Task.detached(priority: .utility) { try Task.checkCancellation(); return try LyricsFileService.read(track: track) }
             return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
         }, fileWriter: @escaping FileWriter = { document, track in
             let work = Task.detached(priority: .utility) { try Task.checkCancellation(); return try LyricsFileService.write(document: document, track: track) }
             return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
         }) {
        self.model = model; self.resolver = resolver ?? model.lyricsResolver
        self.localReader = localReader; self.fileWriter = fileWriter
    }

    static func requestKey(for track: TrackRecord?) -> String {
        guard let track else { return "no-track" }
        return StableID.make(LyricsLookupQuery(track: track).fingerprint, track.fileURL ?? "", track.cuePath ?? "",
                             String(track.startTime ?? 0), String(track.endTime ?? -1))
    }

    var hasSynchronizedLyrics: Bool { !displayLines.isEmpty }
    var sheetTrackTitle: String { sheetTrack?.title ?? track?.title ?? "Lyrics" }
    var canSaveToFiles: Bool {
        guard let track, let document, document.hasContent, !document.isInstrumental else { return false }
        return track.url?.isFileURL == true && model?.sources.contains(where: { $0.id == track.sourceID && $0.kind == .local }) == true
    }

    func activeLineID(at position: Double) -> Int? {
        guard position.isFinite, !displayLines.isEmpty else { return nil }
        var lower = 0, upper = displayLines.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if displayLines[middle].time <= position { lower = middle + 1 } else { upper = middle }
        }
        return lower > 0 ? displayLines[lower - 1].id : nil
    }

    func load(track: TrackRecord?) async { await load(track: track, force: false) }

    private func load(track: TrackRecord?, force: Bool) async {
        cancelLoad()
        self.track = track; notice = nil; document = nil; displayLines = []; plainText = ""; sourceLabel = ""; errorMessage = nil
        guard let track else { state = .idle; return }
        guard let model, let store = model.store else { state = .failed; errorMessage = "The music library is unavailable."; return }
        let id = UUID(); requestID = id; state = .loading
        let local = localReader
        let source = model.sources.first { $0.id == track.sourceID }
        if let source, source.kind == .local { _ = model.accessFolder(source) }
        let resolver = resolver
        let task = Task { [weak self] in
            do {
                let result = try await resolver.resolve(track: track, store: store, local: { value in
                    guard source?.kind == .local else { return nil }
                    return try await local(value)
                }, server: { value in
                    guard source?.kind == .openSubsonic, let source else { return nil }
                    let client = try await model.subsonicClient(source)
                    var structuredError: Error?
                    if let remoteID = value.remoteID {
                        do {
                            if let document = try await client.structuredLyrics(songID: remoteID).first(where: \.hasContent) { return document }
                        } catch is CancellationError { throw CancellationError() }
                        catch { if !Self.isOptionalLyricsUnavailable(error) { structuredError = error } }
                    }
                    do {
                        if let text = try await client.lyrics(artist: value.artist, title: value.title), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            return LRCParser.parse(text, source: .openSubsonic)
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { throw structuredError ?? error }
                    if let structuredError { throw structuredError }
                    return nil
                }, forceRefresh: force)
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                self.apply(result)
            } catch is CancellationError { }
            catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.state = .failed
                self.errorTitle = (error as? LyricsError)?.retryAfter != nil ? "Lyrics Service Busy" : "Unable to Load Lyrics"
                self.errorMessage = error.localizedDescription
            }
        }
        loadTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if requestID == id { loadTask = nil }
    }

    private func cancelLoad() { loadTask?.cancel(); loadTask = nil; requestID = UUID() }
    func cancel() { cancelLoad(); searchTask?.cancel(); searchTask = nil; searchID = UUID(); isSearching = false }
    func reload() async { await load(track: track, force: true) }

    func openSearch() {
        guard let track else { return }
        sheetTrack = track; searchTitle = track.title; searchArtist = track.artist; searchAlbum = track.album
        searchResults = []; candidates = [:]; searchError = nil; isSearching = false; showsSearch = true
    }

    func openEditor() {
        guard let track else { return }
        sheetTrack = track; editedText = document?.originalLRC ?? document?.lrcText ?? plainText
        editorError = nil; showsEditor = true
    }

    func search() async {
        guard let target = sheetTrack else { return }
        let id = UUID(); searchID = id; isSearching = true; searchError = nil
        let query = LyricsLookupQuery(sourceID: target.sourceID, trackID: target.id, title: searchTitle,
                                      artist: searchArtist, album: searchAlbum, duration: LyricsLookupQuery(track: target).duration)
        searchTask?.cancel()
        let resolver = resolver
        let task = Task { try await resolver.search(query) }
        searchTask = task
        do {
            let values = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard searchID == id, showsSearch else { return }
            candidates = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            searchResults = values.map { .init(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album, duration: $0.duration, plainText: $0.document.plainText) }
            if values.isEmpty { searchError = "No matching lyrics were found. Try changing the title, artist, or album." }
        } catch {
            if searchID == id, !Task.isCancelled { searchError = error.localizedDescription }
        }
        if searchID == id { isSearching = false; searchTask = nil }
    }

    func useResult(_ item: LyricsSearchItem) async {
        guard let target = sheetTrack, let document = candidates[item.id]?.document else { return }
        do {
            try await saveOverride(document, for: target)
            showsSearch = false
        } catch { searchError = error.localizedDescription }
    }

    func saveEditedLyrics() async {
        guard let target = sheetTrack else { return }
        guard !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { editorError = "Enter lyrics or paste an LRC document."; return }
        guard editedText.utf8.count <= 2 * 1_024 * 1_024 else { editorError = "The lyrics are larger than 2 MB."; return }
        isSavingEdit = true; editorError = nil
        defer { isSavingEdit = false }
        let text = editedText
        let work = Task.detached(priority: .utility) { LRCParser.parse(text, source: .manual) }
        let document = await work.value
        do { try await saveOverride(document, for: target); showsEditor = false }
        catch { editorError = error.localizedDescription }
    }

    private func saveOverride(_ document: LyricsDocument, for target: TrackRecord) async throws {
        guard let model else { return }
        let query = LyricsLookupQuery(track: target)
        try await model.performLibraryWork { try $0.saveLyrics(.from(document), for: query, manual: true) }
        if track?.sourceID == target.sourceID, track?.id == target.id {
            cancelLoad(); apply(.from(document)); notice = "Lyrics saved in your library."
        }
    }

    func saveToFiles() async {
        guard canSaveToFiles, let target = track, let document, let model,
              let source = model.sources.first(where: { $0.id == target.sourceID && $0.kind == .local }) else { return }
        _ = model.accessFolder(source)
        isSavingToFiles = true; notice = nil
        defer { isSavingToFiles = false }
        do {
            let query = LyricsLookupQuery(track: target)
            try await model.performLibraryWork { try $0.saveLyrics(.from(document), for: query, manual: document.source == .manual) }
            let paths = try await fileWriter(document, target)
            if Self.requestKey(for: track) == Self.requestKey(for: target) {
                notice = "Saved lyrics to " + paths.map(\.lastPathComponent).joined(separator: ", ") + "."
            }
        } catch {
            if Self.requestKey(for: track) == Self.requestKey(for: target) { notice = error.localizedDescription }
        }
    }

    private func apply(_ result: LyricsLookupResult) {
        document = result.document; errorMessage = nil
        plainText = document?.plainText ?? ""; sourceLabel = document?.source.title ?? ""
        displayLines = document?.lines.enumerated().map { .init(id: $0.offset, time: $0.element.startTime, text: $0.element.text) } ?? []
        switch result { case .found: state = .loaded; case .instrumental: state = .instrumental; case .notFound: state = .notFound }
    }

    nonisolated static func isOptionalLyricsUnavailable(_ error: Error) -> Bool {
        if case SourceNetworkError.httpStatus(let status) = error { return [404, 501].contains(status) }
        guard let error = error as? OpenSubsonicError else { return false }
        if [20, 30, 70].contains(error.code) { return true }
        guard error.code == 0 else { return false }
        let message = error.message.lowercased()
        return ["not implemented", "unknown method", "unknown endpoint", "unsupported method", "method not supported"]
            .contains { message.contains($0) }
    }
}
