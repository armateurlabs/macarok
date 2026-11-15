import Foundation

/// Performs only demand-driven retrieval; constructing this actor never contacts a provider.
public actor LyricsResolver {
    public typealias Provider = @Sendable (TrackRecord) async throws -> LyricsDocument?
    private let client: LRCLIBClient

    public init(client: LRCLIBClient = LRCLIBClient()) { self.client = client }

    public func search(_ query: LyricsLookupQuery, text: String? = nil) async throws -> [LyricsCandidate] {
        try await client.search(query, text: text)
    }

    public func resolve(track: TrackRecord, store: LibraryStore,
                        local: Provider = { _ in nil }, server: Provider = { _ in nil },
                        forceRefresh: Bool = false) async throws -> LyricsLookupResult {
        let query = LyricsLookupQuery(track: track)
        let cached = try store.cachedLyrics(for: query)
        if let cached, cached.isManual { return cached.result }
        var earlierError: Error?
        do {
            if let document = try await local(track), document.hasContent {
                try Task.checkCancellation()
                let result = LyricsLookupResult.from(document)
                try store.saveLyrics(result, for: query)
                return result
            }
        } catch is CancellationError { throw CancellationError() }
        catch { earlierError = error }
        try Task.checkCancellation()
        if !forceRefresh, let cached { return cached.result }
        do {
            if let document = try await server(track), document.hasContent {
                try Task.checkCancellation()
                let result = LyricsLookupResult.from(document)
                try store.saveLyrics(result, for: query)
                return result
            }
        } catch is CancellationError { throw CancellationError() }
        catch { earlierError = earlierError ?? error }
        try Task.checkCancellation()
        let result = try await client.lookup(query)
        try Task.checkCancellation()
        if result == .notFound, let earlierError { throw earlierError }
        try store.saveLyrics(result, for: query)
        return result
    }
}
