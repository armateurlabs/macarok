import AppKit
import Foundation
import MacarokCore
import Observation

private actor ScrobblingWorker {
    let store: LibraryStore
    let credentials: any LastFMCredentialStorage
    init(store: LibraryStore, credentials: any LastFMCredentialStorage) { self.store = store; self.credentials = credentials }
    func load() throws -> (LastFMPreferences, LastFMCredentialRecord?) { (try store.lastFMPreferences(), try credentials.load()) }
    func saveCredentials(_ value: LastFMCredentialRecord) throws { try credentials.save(value) }
    func savePreferences(_ value: LastFMPreferences) throws { try store.saveLastFMPreferences(value) }
    func perform<Value: Sendable>(_ body: @Sendable (LibraryStore) throws -> Value) throws -> Value { try body(store) }
}

/// Foreground state only; HTTP, Keychain and SQLite work run outside the main actor.
@MainActor @Observable
final class ScrobblingController {
    @ObservationIgnored private let worker: ScrobblingWorker
    @ObservationIgnored private let transport: LastFMClient.Transport?
    @ObservationIgnored private let monotonic: @Sendable () -> TimeInterval
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let openBrowser: @MainActor (URL) -> Bool
    @ObservationIgnored private let sleeper: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private var credentials: LastFMCredentialRecord?
    @ObservationIgnored private var client: LastFMClient?
    @ObservationIgnored private var preferences = LastFMPreferences()
    @ObservationIgnored private var listening: ListeningSession?
    @ObservationIgnored private var currentTrack: TrackRecord?
    @ObservationIgnored private var currentSource: SourceRecord?
    @ObservationIgnored private var currentOccurrenceID = UUID().uuidString
    @ObservationIgnored private var pendingStartedAt: Date?
    @ObservationIgnored private var authorizationToken: (value: String, created: Date)?
    @ObservationIgnored private var authorizationID = UUID()
    @ObservationIgnored private var deliveryID = UUID()
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingTask: Task<Void, Never>?
    @ObservationIgnored private var enqueueTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    var apiKeyInput = ""
    var apiSecretInput = ""
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var isConfigured = false
    private(set) var isEnabled = false
    private(set) var sharesNowPlaying = true
    private(set) var excludedSourceIDs: Set<String> = []
    private(set) var username: String?
    private(set) var needsAuthorizationCompletion = false
    private(set) var pendingCount = 0
    private(set) var ignoredCount = 0
    private(set) var failedCount = 0
    private(set) var isSubmitting = false
    private(set) var needsReauthentication = false
    private(set) var errorMessage: String?
    private(set) var notice: String?

    init(store: LibraryStore, credentials: any LastFMCredentialStorage = LastFMKeychainStore(),
         transport: LastFMClient.Transport? = nil,
         monotonic: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         now: @escaping @Sendable () -> Date = { Date() },
         openBrowser: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        worker = ScrobblingWorker(store: store, credentials: credentials)
        self.transport = transport; self.monotonic = monotonic; self.now = now
        self.openBrowser = openBrowser; sleeper = sleep
    }

    /// Loading saved credentials never initiates authentication or contacts Last.fm.
    func start() async {
        guard !started else { return }
        started = true; isLoading = true
        defer { isLoading = false }
        do {
            let (preferences, credentials) = try await worker.load()
            self.preferences = preferences; self.credentials = credentials
            apiKeyInput = credentials?.application.apiKey ?? ""; apiSecretInput = credentials?.application.sharedSecret ?? ""
            isConfigured = credentials?.application.isValid == true
            username = credentials?.session?.username
            if let credentials { client = LastFMClient(credentials: credentials.application, transport: transport, now: now) }
            applyPreferences()
            resetListeningSession()
            await refreshSummary()
        } catch { errorMessage = error.localizedDescription }
    }

    func saveAPIKeys() async {
        guard !isWorking else { return }
        let application = LastFMAppCredentials(apiKey: apiKeyInput, sharedSecret: apiSecretInput)
        guard application.isValid else { errorMessage = LastFMError.invalidConfiguration.localizedDescription; return }
        isWorking = true; errorMessage = nil; notice = nil
        defer { isWorking = false }
        do {
            if credentials?.application == application {
                notice = "Your personal API credentials are already saved in Keychain."; return
            }
            if credentials?.application != application {
                if var session = listening, let submission = session.finish(monotonic: monotonic(), date: now()) { enqueue(submission) }
                listening = nil; pendingStartedAt = nil; stopDelivery(); authorizationID = UUID(); authorizationToken = nil; needsAuthorizationCompletion = false
                preferences.enabled = false; isEnabled = false
                let record = LastFMCredentialRecord(application: application)
                try await worker.saveCredentials(record)
                credentials = record; username = nil
                try await worker.savePreferences(preferences)
            }
            client = LastFMClient(credentials: application, transport: transport, now: now); isConfigured = true
            applyPreferences(); await refreshSummary()
            notice = "Your personal API credentials were saved in Keychain."
        } catch { errorMessage = error.localizedDescription }
    }

    func connect() async {
        guard !isWorking, let client, isConfigured else { return }
        isWorking = true; errorMessage = nil; notice = nil
        let id = UUID(); authorizationID = id
        defer { isWorking = false }
        do {
            let token = try await client.requestToken()
            guard authorizationID == id else { return }
            var components = URLComponents(string: "https://www.last.fm/api/auth/")!
            components.queryItems = [URLQueryItem(name: "api_key", value: credentials?.application.apiKey), URLQueryItem(name: "token", value: token)]
            guard let url = components.url, openBrowser(url) else {
                errorMessage = "The authorization page could not be opened. Try connecting again."; return
            }
            authorizationToken = (token, now()); needsAuthorizationCompletion = true
            notice = "Approve Macarok in your browser, then click Complete Connection."
        } catch { if authorizationID == id { errorMessage = error.localizedDescription } }
    }

    func completeAuthorization() async {
        guard !isWorking, let token = authorizationToken, let client, var record = credentials else { return }
        guard now().timeIntervalSince(token.created) < 3_600 else {
            authorizationToken = nil; needsAuthorizationCompletion = false
            errorMessage = "The authorization token expired. Start the connection again."; return
        }
        isWorking = true; errorMessage = nil
        let id = authorizationID
        defer { isWorking = false }
        do {
            let session = try await client.session(token: token.value)
            guard authorizationID == id else { return }
            record.session = session
            try await worker.saveCredentials(record)
            guard authorizationID == id else { return }
            stopDelivery(); credentials = record; username = session.username; needsReauthentication = false
            authorizationToken = nil; needsAuthorizationCompletion = false
            preferences.enabled = true
            try await worker.savePreferences(preferences)
            applyPreferences(); resetListeningSession(); await refreshSummary()
            notice = "Connected to Last.fm as \(session.username)."
            retryPending()
        } catch { if authorizationID == id { errorMessage = error.localizedDescription } }
    }

    func disconnect() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        authorizationID = UUID(); authorizationToken = nil; needsAuthorizationCompletion = false
        preferences.enabled = false; isEnabled = false; listening = nil; pendingStartedAt = nil
        stopDelivery()
        await enqueueTask?.value
        do {
            if var record = credentials {
                record.session = nil
                try await worker.saveCredentials(record); credentials = record
            }
            try await worker.savePreferences(preferences)
            username = nil; pendingCount = 0; ignoredCount = 0; failedCount = 0
            notice = "Disconnected. Pending scrobbles are kept for this account."; errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isWorking else { return }
        guard !enabled || (credentials?.session != nil && !needsReauthentication) else { return }
        guard enabled != isEnabled else { return }
        preferences.enabled = enabled
        if !enabled { isEnabled = false; stopDelivery(); listening = nil; pendingStartedAt = nil }
        do {
            try await worker.savePreferences(preferences)
            applyPreferences(); resetListeningSession()
            if enabled { retryPending() }
        } catch { errorMessage = error.localizedDescription }
    }

    func setSharesNowPlaying(_ enabled: Bool) async {
        preferences.sharesNowPlaying = enabled
        sharesNowPlaying = enabled
        if !enabled { nowPlayingTask?.cancel() }
        do { try await worker.savePreferences(preferences); applyPreferences() }
        catch { errorMessage = error.localizedDescription }
    }

    func setSource(_ sourceID: String, excluded: Bool) async {
        if excluded { preferences.excludedSourceIDs.insert(sourceID) } else { preferences.excludedSourceIDs.remove(sourceID) }
        if excluded, currentTrack?.sourceID == sourceID { listening = nil; pendingStartedAt = nil; nowPlayingTask?.cancel() }
        do {
            try await worker.savePreferences(preferences); applyPreferences()
            if currentTrack?.sourceID == sourceID { resetListeningSession() }
        }
        catch { errorMessage = error.localizedDescription }
    }

    func begin(track: TrackRecord, source: SourceRecord?, occurrenceID: UUID = UUID(), startedAt: Date? = nil) {
        end(); nowPlayingTask?.cancel()
        currentTrack = track; currentSource = source; currentOccurrenceID = occurrenceID.uuidString
        if eligible(track: track, source: source), isEnabled {
            listening = ListeningSession(track: LastFMTrackSnapshot(track: track), occurrenceID: currentOccurrenceID)
            pendingStartedAt = startedAt.flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil }
        }
    }

    func update(isPlaying: Bool, isBuffering: Bool, position: Double, duration: Double) {
        guard isEnabled, var session = listening else { return }
        // Native playback can begin before the main actor adopts the queue entry. Preserve its
        // wall-clock timestamp, but establish listening time only from observations made here.
        let firstActive = isPlaying && !isBuffering && session.startedAt == nil
        let date = firstActive ? pendingStartedAt ?? now() : now()
        let update = session.sample(isPlaying: isPlaying, isBuffering: isBuffering, position: position,
                                    duration: duration, monotonic: monotonic(), date: date)
        listening = session
        if update.beganPlaying { pendingStartedAt = nil; sendNowPlaying(session.track); retryPending() }
        if let submission = update.submission { enqueue(submission) }
    }

    func seek() {
        guard var session = listening else { return }
        let submission = session.seek(monotonic: monotonic(), date: now())
        listening = session
        if let submission { enqueue(submission) }
    }
    func suspend() {
        guard var session = listening else { return }
        let submission = session.suspend(monotonic: monotonic(), date: now())
        listening = session
        if let submission { enqueue(submission) }
    }

    func end(discardUnsampledTime: Bool = false, atMonotonic: TimeInterval? = nil, at date: Date? = nil) {
        let boundary = atMonotonic.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        // An exact native handoff boundary includes the outgoing track's final observed interval.
        // Without that boundary, discard conservatively rather than credit a successor's audio.
        if discardUnsampledTime && boundary == nil { listening?.suspend() }
        nowPlayingTask?.cancel(); nowPlayingTask = nil
        let finishedAt = date.flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil } ?? now()
        if isEnabled, var session = listening, let submission = session.finish(monotonic: boundary ?? monotonic(), date: finishedAt) { enqueue(submission) }
        listening = nil; currentTrack = nil; currentSource = nil; pendingStartedAt = nil
    }

    /// Makes qualified events durable; quitting does not wait for an unavailable network.
    func flush() async { await enqueueTask?.value }

    func retryPending() {
        guard isEnabled, drainTask == nil, let record = credentials, let session = record.session,
              let accountID = record.accountID, let client else { return }
        let id = deliveryID
        drainTask = Task { [weak self] in
            guard let self else { return }
            await self.drain(accountID: accountID, session: session, client: client, id: id)
            if self.deliveryID == id { self.drainTask = nil; self.isSubmitting = false }
        }
    }

    private func eligible(track: TrackRecord, source: SourceRecord?) -> Bool {
        guard let source, [.local, .openSubsonic].contains(source.kind), !preferences.excludedSourceIDs.contains(source.id) else { return false }
        return LastFMTrackSnapshot(track: track).isEligible
    }

    private func resetListeningSession() {
        listening = nil; pendingStartedAt = nil
        if let track = currentTrack, eligible(track: track, source: currentSource), isEnabled {
            listening = ListeningSession(track: LastFMTrackSnapshot(track: track), occurrenceID: currentOccurrenceID)
        }
    }

    private func applyPreferences() {
        isEnabled = preferences.enabled && credentials?.session != nil
        sharesNowPlaying = preferences.sharesNowPlaying; excludedSourceIDs = preferences.excludedSourceIDs
    }

    private func stopDelivery() {
        deliveryID = UUID(); drainTask?.cancel(); drainTask = nil; nowPlayingTask?.cancel(); nowPlayingTask = nil; isSubmitting = false
    }

    private func enqueue(_ submission: LastFMSubmission) {
        guard let accountID = credentials?.accountID else { return }
        let previous = enqueueTask, worker = worker
        enqueueTask = Task { [weak self] in
            await previous?.value
            do {
                try await worker.perform { try $0.enqueueLastFM(submission, accountID: accountID) }
                await self?.refreshSummary(); self?.retryPending()
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    private func sendNowPlaying(_ track: LastFMTrackSnapshot) {
        guard sharesNowPlaying, let session = credentials?.session, let client else { return }
        nowPlayingTask?.cancel()
        let id = deliveryID
        nowPlayingTask = Task { [weak self] in
            do { try await client.nowPlaying(track: track, session: session) }
            catch let error as LastFMError where error.isInvalidSession {
                guard let self, self.deliveryID == id, !Task.isCancelled else { return }
                await self.requireReconnection()
            } catch { /* Now Playing is transient and is never queued or retried. */ }
        }
    }

    private func refreshSummary() async {
        guard let accountID = credentials?.accountID else { pendingCount = 0; ignoredCount = 0; failedCount = 0; return }
        do {
            let summary = try await worker.perform { try $0.lastFMSummary(accountID: accountID) }
            guard credentials?.accountID == accountID else { return }
            pendingCount = summary.pending; ignoredCount = summary.ignored; failedCount = summary.failed
        } catch { errorMessage = error.localizedDescription }
    }

    private func requireReconnection() async {
        preferences.enabled = false; isEnabled = false; needsReauthentication = true; listening = nil; pendingStartedAt = nil
        stopDelivery()
        do { try await worker.savePreferences(preferences) } catch { }
        errorMessage = LastFMError.api(code: 9, message: "").localizedDescription
    }

    private func drain(accountID: String, session: LastFMSession, client: LastFMClient, id: UUID) async {
        while deliveryID == id, isEnabled, !Task.isCancelled {
            do {
                let date = now()
                let batch = try await worker.perform { try $0.lastFMBatch(accountID: accountID, at: date) }
                guard deliveryID == id, !Task.isCancelled else { return }
                if batch.isEmpty {
                    guard let next = try await worker.perform({ try $0.nextLastFMAttempt(accountID: accountID) }) else { return }
                    try await wait(until: next); continue
                }
                isSubmitting = true
                do {
                    let outcomes = try await client.scrobble(batch.map(\.submission), session: session)
                    guard deliveryID == id, !Task.isCancelled else { return }
                    try await worker.perform { try $0.completeLastFM(outcomes, accountID: accountID) }
                    errorMessage = nil
                    await refreshSummary()
                    try await sleeper(1)
                } catch {
                    guard deliveryID == id, !Task.isCancelled else { return }
                    if let error = error as? LastFMError, error.isInvalidSession { await requireReconnection(); return }
                    let ids = batch.map(\.submission.id)
                    let serviceError = error as? LastFMError
                    if serviceError?.isRetryable == false {
                        errorMessage = error.localizedDescription
                        if let serviceError, case .api(let code, _) = serviceError, [4, 10, 13, 26].contains(code) {
                            preferences.enabled = false; isEnabled = false; listening = nil; nowPlayingTask?.cancel()
                            try await worker.savePreferences(preferences)
                            return
                        }
                        try await worker.perform { try $0.failLastFM(ids, accountID: accountID, message: error.localizedDescription) }
                        await refreshSummary(); continue
                    }
                    let attempt = min(10, batch.map(\.attempts).max() ?? 0)
                    let backoff = min(3_600, 5 * pow(2, Double(attempt)))
                    let rateLimited: Bool = { if let serviceError, case .api(29, _) = serviceError { true } else { false } }()
                    let delay = max(rateLimited ? 60 : backoff, serviceError?.retryAfter ?? 0)
                    let retry = now().addingTimeInterval(delay + Double.random(in: 0...min(5, delay * 0.1)))
                    try await worker.perform { try $0.deferLastFM(ids, accountID: accountID, until: retry) }
                    errorMessage = "Last.fm is unavailable. Pending scrobbles will be retried automatically."
                    isSubmitting = false
                    await refreshSummary(); try await wait(until: retry)
                }
            } catch {
                if deliveryID == id, !Task.isCancelled { errorMessage = error.localizedDescription }
                return
            }
        }
    }

    private func wait(until date: Date) async throws {
        while date > now() {
            try Task.checkCancellation()
            try await sleeper(max(0, min(60, date.timeIntervalSince(now()))))
        }
    }
}
