import Darwin
import Foundation
import MacarokCore

public struct AudioFingerprint: Sendable, Equatable, Codable {
    public let duration: Double
    public let fingerprint: String
    public let warning: String?

    public init(duration: Double, fingerprint: String, warning: String? = nil) {
        self.duration = duration; self.fingerprint = fingerprint; self.warning = warning
    }
}

public enum AudioIdentificationError: LocalizedError, Sendable {
    case helperUnavailable
    case localFileRequired
    case cueSegmentUnsupported
    case missingClientKey
    case fingerprintFailed
    case timedOut
    case service(String)

    public var errorDescription: String? {
        switch self {
        case .helperUnavailable: return "Audio identification is unavailable in this build. Build Macarok with its optional Chromaprint helper."
        case .localFileRequired: return "Audio identification currently requires a local audio file."
        case .cueSegmentUnsupported: return "Audio identification for individual CUE tracks is not available yet. Use Find Metadata to search by artist and album."
        case .missingClientKey: return "Enter an AcoustID application client key. This is different from an AcoustID user submission key."
        case .fingerprintFailed: return "Chromaprint could not identify enough audio in this file to create a fingerprint."
        case .timedOut: return "Generating the audio fingerprint took too long."
        case .service(let message): return "AcoustID: \(message)"
        }
    }
}

/// Uses the unmodified upstream fpcalc executable without shell command interpolation.
public struct ChromaprintClient: Sendable {
    private let executableURL: URL?

    public init(executableURL: URL? = ChromaprintClient.bundledHelperURL) {
        self.executableURL = executableURL
    }

    public static var bundledHelperURL: URL? {
        if let path = ProcessInfo.processInfo.environment["MACAROK_FPCALC_PATH"], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        guard let support = Bundle.main.sharedSupportURL else { return nil }
        let url = support.appendingPathComponent("Helpers/fpcalc")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    public var isAvailable: Bool { executableURL != nil }

    public func fingerprint(url: URL, isCUETrack: Bool = false) async throws -> AudioFingerprint {
        guard !isCUETrack else { throw AudioIdentificationError.cueSegmentUnsupported }
        guard url.isFileURL else { throw AudioIdentificationError.localFileRequired }
        guard let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AudioIdentificationError.helperUnavailable
        }
        let runner = FingerprintProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try runner.run(executable: executableURL, audio: url)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { runner.cancel() }
    }
}

private final class FingerprintProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; let running = process; lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }

    func run(executable: URL, audio: URL) throws -> AudioFingerprint {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokFingerprint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("fingerprint.json")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let task = Process()
        task.executableURL = executable
        task.arguments = ["-json", "-length", "120", "--", audio.path]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in ended.signal() }
        lock.lock()
        guard !cancelled else { lock.unlock(); throw CancellationError() }
        process = task
        // Keep cancellation ordered after launch so it cannot miss a just-starting task.
        do { try task.run(); lock.unlock() }
        catch { process = nil; lock.unlock(); throw AudioIdentificationError.fingerprintFailed }
        defer { lock.lock(); process = nil; let wasCancelled = cancelled; lock.unlock(); if wasCancelled && task.isRunning { task.terminate() } }
        if ended.wait(timeout: .now() + 45) != .success {
            task.terminate()
            if ended.wait(timeout: .now() + 2) != .success { kill(task.processIdentifier, SIGKILL); task.waitUntilExit() }
            throw AudioIdentificationError.timedOut
        }
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }
        // The pinned helper can finish a usable fingerprint, print JSON, and then return 3
        // after a decoder read error. Other failures and interrupted processes stay fatal.
        guard task.terminationReason == .exit, [0, 3].contains(task.terminationStatus),
              let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_024 * 1_024,
              let result = try? JSONDecoder().decode(AudioFingerprint.self, from: Data(contentsOf: outputURL)),
              result.duration.isFinite, result.duration > 0, !result.fingerprint.isEmpty,
              result.fingerprint.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              result.fingerprint.count < 100_000 else { throw AudioIdentificationError.fingerprintFailed }
        return AudioFingerprint(duration: result.duration, fingerprint: result.fingerprint,
            warning: task.terminationStatus == 3
                ? "Some audio could not be decoded. Identification uses the readable portion of this file."
                : nil)
    }
}

public struct AcoustIDRecordingMatch: Identifiable, Sendable, Equatable {
    public let acoustID: String
    public let recordingID: String
    public let title: String
    public let artist: String
    public let albums: [String]
    public let score: Double
    public let duration: Double?
    public var id: String { recordingID }

    public func proposal(for track: TrackRecord) -> MetadataProposal {
        let values = [("title", track.title, title), ("artist", track.artist, artist)]
        return MetadataProposal(trackID: track.id, changes: values.compactMap { field, old, new in
            new.isEmpty || old == new ? nil : MetadataChange(field: field, currentValue: old, proposedValue: new)
        })
    }
}

/// A lookup-only client. Audio bytes, paths, and existing music tags are never sent.
public actor AcoustIDClient {
    private let transport: SourceTransport
    private let endpoint: URL
    private var nextRequest = Date.distantPast

    public init(transport: SourceTransport = SourceTransport(sourceID: "metadata.acoustid"),
                endpoint: URL = URL(string: "https://api.acoustid.org/v2/lookup")!) {
        self.transport = transport; self.endpoint = endpoint
    }

    public func lookup(_ fingerprint: AudioFingerprint, clientKey: String) async throws -> [AcoustIDRecordingMatch] {
        let key = clientKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AudioIdentificationError.missingClientKey }
        guard fingerprint.duration.isFinite, fingerprint.duration > 0, fingerprint.duration < 1_000_000,
              !fingerprint.fingerprint.isEmpty, fingerprint.fingerprint.count < 100_000 else {
            throw AudioIdentificationError.fingerprintFailed
        }
        let scheduled = max(Date(), nextRequest)
        nextRequest = scheduled.addingTimeInterval(0.4)
        let delay = scheduled.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        try Task.checkCancellation()
        var form = URLComponents()
        form.queryItems = [
            .init(name: "format", value: "json"), .init(name: "client", value: key),
            .init(name: "duration", value: String(Int(fingerprint.duration))),
            .init(name: "fingerprint", value: fingerprint.fingerprint),
            .init(name: "meta", value: "recordings releasegroups compress")
        ]
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Macarok/0.1.0 (https://github.com/armateurlabs/macarok)", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await transport.response(for: request)
        guard (200...299).contains(response.statusCode) else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["status"] as? String == "error",
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AudioIdentificationError.service(String(message.prefix(300)))
            }
            throw SourceNetworkError.httpStatus(response.statusCode)
        }
        return try Self.parseResponse(data)
    }

    static func parseResponse(_ data: Data) throws -> [AcoustIDRecordingMatch] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceNetworkError.invalidResponse
        }
        guard json["status"] as? String == "ok" else {
            let error = json["error"] as? [String: Any]
            throw AudioIdentificationError.service(String((error?["message"] as? String ?? "The lookup failed.").prefix(300)))
        }
        var unique: [String: AcoustIDRecordingMatch] = [:]
        for result in json["results"] as? [[String: Any]] ?? [] {
            guard let acousticID = result["id"] as? String, let score = result["score"] as? Double,
                  score.isFinite, (0...1).contains(score) else { continue }
            for recording in result["recordings"] as? [[String: Any]] ?? [] {
                guard let id = recording["id"] as? String, UUID(uuidString: id) != nil,
                      let title = recording["title"] as? String, !title.isEmpty else { continue }
                let credits = recording["artists"] as? [[String: Any]] ?? []
                let artist = credits.enumerated().map { index, credit in
                    (credit["name"] as? String ?? "") + (credit["joinphrase"] as? String ?? (index + 1 < credits.count ? " & " : ""))
                }.joined()
                let albums = (recording["releasegroups"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
                let match = AcoustIDRecordingMatch(acoustID: acousticID, recordingID: id, title: title,
                    artist: artist, albums: Array(Set(albums)).sorted(), score: score,
                    duration: (recording["duration"] as? NSNumber)?.doubleValue)
                if unique[id].map({ $0.score < score }) ?? true { unique[id] = match }
            }
        }
        return Array(unique.values.sorted { $0.score == $1.score ? $0.title < $1.title : $0.score > $1.score }.prefix(12))
    }
}

/// Separate Keychain service: identification keys cannot collide with source credentials.
public enum AcoustIDClientKeyStore {
    private static let store = KeychainCredentialStore(service: "labs.armateur.Macarok.acoustid")
    public static func load() throws -> String? { try store.load(sourceID: "application-client")?.apiKey }
    public static func save(_ key: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { try delete(); return }
        try store.save(SourceCredentials(apiKey: value), sourceID: "application-client")
    }
    public static func delete() throws { try store.delete(sourceID: "application-client") }
}
