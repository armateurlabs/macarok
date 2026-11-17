import AppKit
import Foundation
import MacarokCore

struct ArtistArtworkTarget: Identifiable, Equatable {
    var name: String
    /// Opens the chooser with an online search already running.
    var searchesOnOpen = false
    var id: String { ArtistArtworkKey.make(name) }
}

enum ArtistArtworkServices {
    static let wikipedia = WikipediaImageClient()
    /// How long an automatic search that found nothing is trusted before trying again.
    static let notFoundInterval: TimeInterval = 30 * 24 * 60 * 60
    /// How long a search that failed (offline, rate limited) waits before trying again.
    static let failureInterval: TimeInterval = 60 * 60

    static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Macarok/0.1 (macOS; https://github.com/armateurlabs/macarok)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try normalizedImage(data)
    }

    static func normalizedImage(_ data: Data) throws -> Data {
        guard data.count <= 32 * 1_024 * 1_024, let image = NSImage(data: data) else { throw AppFailure.invalidArtwork }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: [0xFF, 0xD8]) { return data }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw AppFailure.invalidArtwork }
        return png
    }
}

extension AppModel {
    func artistArtworkPath(for name: String) -> String? { artistArtwork[ArtistArtworkKey.make(name)]?.path }

    func beginArtistArtworkEditing(_ name: String, search: Bool = false) {
        guard ArtistArtworkKey.isMeaningful(name) else { return }
        recordUserCenterNavigation()
        artistArtworkTarget = ArtistArtworkTarget(name: name, searchesOnOpen: search)
    }

    /// Loads the saved picture, or looks one up on Last.fm and then Wikipedia and saves it to the library.
    func ensureArtistArtwork(_ name: String) async {
        guard ArtistArtworkKey.isMeaningful(name), store != nil else { return }
        if !artistArtworkLoaded {
            artistArtworkLoaded = true
            if let saved = try? await performLibraryWork({ try $0.allArtistArtwork() }) {
                for record in saved where artistArtwork[record.key] == nil { artistArtwork[record.key] = record }
            }
        }
        let key = ArtistArtworkKey.make(name)
        if let existing = artistArtwork[key], existing.path != nil || Date().timeIntervalSince(existing.checkedAt) < ArtistArtworkServices.notFoundInterval { return }
        guard findsArtistPicturesOnline, artistArtworkTasks.insert(key).inserted else { return }
        defer { artistArtworkTasks.remove(key) }

        do {
            var found: (path: String, origin: String)?
            if let candidate = try await automaticArtistImage(for: name) {
                let data = try await ArtistArtworkServices.download(candidate.imageURL)
                found = (try await cacheArtwork(data, key: StableID.make("artist", key, candidate.imageURL.absoluteString)).path, candidate.origin)
            }
            let (path, origin) = (found?.path, found?.origin)
            let record = try await performLibraryWork { store in
                try store.saveArtistArtwork(name: name, path: path, origin: origin, manual: false)
                return try store.artistArtwork(named: name)
            }
            artistArtwork[key] = record
        } catch {
            // Offline or rate limited: try again later in this session without recording "not found".
            artistArtwork[key] = ArtistArtworkRecord(key: key, name: name, path: nil, origin: nil, manual: false,
                checkedAt: Date().addingTimeInterval(ArtistArtworkServices.failureInterval - ArtistArtworkServices.notFoundInterval))
        }
    }

    /// Last.fm first (when connected), then the artist's Wikipedia article.
    private func automaticArtistImage(for name: String) async throws -> ArtistImageCandidate? {
        if let client = scrobbling?.similarityClient, let image = try? await client.artistImage(artist: name) { return image }
        return try await ArtistArtworkServices.wikipedia.bestArtistImage(for: name)
    }

    /// Every picture found online for the chooser, Last.fm first.
    func searchArtistImages(for name: String) async throws -> [ArtistImageCandidate] {
        var results: [ArtistImageCandidate] = []
        if let client = scrobbling?.similarityClient, let image = try? await client.artistImage(artist: name) { results.append(image) }
        results += try await ArtistArtworkServices.wikipedia.artistImages(for: name)
        var seen = Set<String>()
        return results.filter { seen.insert($0.id).inserted }
    }

    func saveArtistArtwork(_ data: Data, name: String, origin: String) async throws {
        let key = ArtistArtworkKey.make(name)
        let previous = artistArtwork[key]?.path
        let url = try await cacheArtwork(data, key: StableID.make("artist", key, UUID().uuidString))
        let record = try await performLibraryWork { store in
            try store.saveArtistArtwork(name: name, path: url.path, origin: origin, manual: true)
            return try store.artistArtwork(named: name)
        }
        artistArtwork[key] = record
        removeCachedArtistImage(previous, keeping: url.path)
    }

    /// Forgets the current picture, including a chosen one, and searches online again.
    func resetArtistArtwork(_ name: String) async {
        let key = ArtistArtworkKey.make(name)
        let previous = artistArtwork[key]?.path
        do { try await performLibraryWork { try $0.removeArtistArtwork(named: name) } }
        catch { fail("Could not reset artist picture", error.localizedDescription); return }
        artistArtwork[key] = nil
        removeCachedArtistImage(previous, keeping: nil)
        await ensureArtistArtwork(name)
    }

    private func removeCachedArtistImage(_ path: String?, keeping current: String?) {
        guard let path, path != current, let store else { return }
        let directory = URL(fileURLWithPath: store.database.path).deletingLastPathComponent().appendingPathComponent("Artwork", isDirectory: true)
        let url = URL(fileURLWithPath: path)
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
