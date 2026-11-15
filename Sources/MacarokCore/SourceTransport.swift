import Foundation
import CryptoKit
import Security

public enum SourceNetworkError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case invalidRange
    case httpStatus(Int)
    case missingCredentials
    case keychain(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a valid HTTP or HTTPS server URL."
        case .invalidResponse: return "The server returned an invalid response."
        case .invalidRange: return "The server returned an invalid audio byte range."
        case .httpStatus(let status): return "The server returned HTTP \(status)."
        case .missingCredentials: return "The source credentials are missing."
        case .keychain(let status): return "Keychain could not complete the operation (\(status))."
        }
    }
}

public struct SourceCredentials: Codable, Sendable, Equatable {
    public var username: String
    public var password: String
    public var apiKey: String?

    public init(username: String = "", password: String = "", apiKey: String? = nil) {
        self.username = username
        self.password = password
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
    }
}

public final class KeychainCredentialStore: @unchecked Sendable {
    public static let shared = KeychainCredentialStore()
    private let service: String

    public init(service: String = "labs.armateur.Macarok.sources") { self.service = service }

    public func save(_ credentials: SourceCredentials, sourceID: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: sourceID]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw SourceNetworkError.keychain(added) }
        } else if status != errSecSuccess { throw SourceNetworkError.keychain(status) }
    }

    public func load(sourceID: String) throws -> SourceCredentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: sourceID,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SourceNetworkError.keychain(status) }
        guard let data = result as? Data else { throw SourceNetworkError.invalidResponse }
        return try JSONDecoder().decode(SourceCredentials.self, from: data)
    }

    public func delete(sourceID: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: sourceID]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SourceNetworkError.keychain(status)
        }
    }
}

public struct ServerCertificateChallenge: Identifiable, Sendable {
    public let id: UUID
    public let sourceID: String
    public let host: String
    public let port: Int
    public let subject: String
    public let fingerprint: String
    public let certificateDER: Data
    public let previouslyTrustedFingerprint: String?
    public let reason: String

    public init(sourceID: String, host: String, port: Int, subject: String,
                fingerprint: String, certificateDER: Data,
                previouslyTrustedFingerprint: String?, reason: String) {
        id = UUID()
        self.sourceID = sourceID
        self.host = host
        self.port = port
        self.subject = subject
        self.fingerprint = fingerprint
        self.certificateDER = certificateDER
        self.previouslyTrustedFingerprint = previouslyTrustedFingerprint
        self.reason = reason
    }
}

public final class CertificateTrustStore: @unchecked Sendable {
    public static let shared = CertificateTrustStore()
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let storageKey: String

    public init(defaults: UserDefaults = .standard, storageKey: String = "Macarok.TrustedCertificates") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    private func key(sourceID: String, host: String, port: Int) -> String {
        "\(sourceID)|\(host.lowercased())|\(port)"
    }

    public func trustedFingerprint(sourceID: String, host: String, port: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return defaults.dictionary(forKey: storageKey)?[key(sourceID: sourceID, host: host, port: port)] as? String
    }

    public func trust(_ fingerprint: String, sourceID: String, host: String, port: Int) {
        lock.lock(); defer { lock.unlock() }
        var values = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        values[key(sourceID: sourceID, host: host, port: port)] = fingerprint
        defaults.set(values, forKey: storageKey)
    }

    public func revoke(sourceID: String, host: String? = nil, port: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        var values = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        if let host, let port { values.removeValue(forKey: key(sourceID: sourceID, host: host, port: port)) }
        else { values = values.filter { !$0.key.hasPrefix(sourceID + "|") } }
        defaults.set(values, forKey: storageKey)
    }

    public static func fingerprint(for certificateDER: Data) -> String {
        SHA256.hash(data: certificateDER).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

public final class SourceTransport: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    public typealias CertificateApproval = @Sendable (ServerCertificateChallenge) async -> Bool
    public let sourceID: String
    public let certificateStore: CertificateTrustStore
    private let approval: CertificateApproval?
    private let configuration: URLSessionConfiguration
    private var session: URLSession!
    private var playbackSession: URLSession!
    private var playbackDelegate: SourceTransferDelegate!
    private var downloadSession: URLSession!
    private var downloadDelegate: SourceTransferDelegate!

    public init(sourceID: String, configuration: URLSessionConfiguration = .ephemeral,
                certificateStore: CertificateTrustStore = .shared,
                certificateApproval: CertificateApproval? = nil) {
        self.sourceID = sourceID
        self.configuration = configuration
        self.certificateStore = certificateStore
        self.approval = certificateApproval
        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        playbackDelegate = SourceTransferDelegate(owner: self)
        downloadDelegate = SourceTransferDelegate(owner: self)
        let playbackQueue = OperationQueue()
        playbackQueue.name = "Macarok.PlaybackHTTP.\(sourceID)"
        playbackQueue.qualityOfService = .userInitiated
        playbackQueue.maxConcurrentOperationCount = 1
        let downloadQueue = OperationQueue()
        downloadQueue.name = "Macarok.DownloadHTTP.\(sourceID)"
        downloadQueue.qualityOfService = .utility
        downloadQueue.maxConcurrentOperationCount = 1
        // Keep playback sockets and callbacks independent of catalog, artwork, and download work.
        let playbackConfiguration = configuration.copy() as! URLSessionConfiguration
        playbackConfiguration.urlCache = nil
        playbackConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        playbackSession = URLSession(configuration: playbackConfiguration, delegate: playbackDelegate, delegateQueue: playbackQueue)
        downloadSession = URLSession(configuration: configuration, delegate: downloadDelegate, delegateQueue: downloadQueue)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, Self.isValidURL(url) else {
            throw SourceNetworkError.invalidURL
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SourceNetworkError.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw SourceNetworkError.httpStatus(response.statusCode) }
        return (data, response)
    }

    public func data(from url: URL) async throws -> Data {
        try await data(for: URLRequest(url: url)).0
    }

    public func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        guard let url = request.url, Self.isValidURL(url) else {
            throw SourceNetworkError.invalidURL
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw SourceNetworkError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            bytes.task.cancel()
            throw SourceNetworkError.httpStatus(response.statusCode)
        }
        return (bytes, response)
    }

    /// Chunk callbacks run in order on the playback session's dedicated delegate queue. A consumer
    /// may wait there for buffer capacity; it never occupies Swift's cooperative executor.
    /// The returned task is suspended so the consumer can install cancellation state before resuming it.
    @discardableResult
    public func startPlaybackStream(for request: URLRequest,
                                    onResponse: @escaping @Sendable (HTTPURLResponse) throws -> Void,
                                    onData: @escaping @Sendable (Data) throws -> Void,
                                    onComplete: @escaping @Sendable (Error?) -> Void) throws -> URLSessionDataTask {
        guard let url = request.url, Self.isValidURL(url) else { throw SourceNetworkError.invalidURL }
        var request = request
        request.networkServiceType = .avStreaming
        let task = playbackSession.dataTask(with: request)
        task.priority = URLSessionTask.highPriority
        playbackDelegate.register(task, response: onResponse, data: onData, completion: onComplete)
        return task
    }

    public func range(from url: URL, offset: Int64, length: Int64) async throws -> (Data, HTTPURLResponse) {
        guard offset >= 0, length > 0, length - 1 <= Int64.max - offset else { throw SourceNetworkError.invalidRange }
        let end = offset + length - 1
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await data(for: request)
        guard response.statusCode == 206,
              let header = response.value(forHTTPHeaderField: "Content-Range"),
              let range = BufferedHTTPInputStream.contentRange(header),
              range.start == UInt64(offset), range.end <= UInt64(end),
              UInt64(data.count) == range.end - range.start + 1,
              response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            throw SourceNetworkError.invalidRange
        }
        return (data, response)
    }

    @discardableResult
    public func download(from url: URL, to destination: URL,
                         progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> URL {
        guard Self.isValidURL(url) else {
            throw SourceNetworkError.invalidURL
        }
        let cancellation = SourceTransferCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = downloadSession.downloadTask(with: URLRequest(url: url))
                task.priority = URLSessionTask.lowPriority
                downloadDelegate.register(task, destination: destination, progress: progress) {
                    continuation.resume(with: $0)
                }
                cancellation.install(task)
                task.resume()
            }
        } onCancel: { cancellation.cancel() }
    }

    public func invalidate() {
        playbackDelegate.cancelStreams()
        session.invalidateAndCancel()
        playbackSession.invalidateAndCancel()
        downloadSession.invalidateAndCancel()
    }

    private static func isValidURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    func handle(_ challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let protection = challenge.protectionSpace
        guard protection.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = protection.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.previousFailureCount < 1,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = certificates.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let fingerprint = CertificateTrustStore.fingerprint(for: der)
        let host = protection.host.lowercased()
        let port = protection.port > 0 ? protection.port : 443
        let previous = certificateStore.trustedFingerprint(sourceID: sourceID, host: host, port: port)
        let systemTrusted = SecTrustEvaluateWithError(trust, nil)

        if systemTrusted, previous == nil || previous == fingerprint {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Pinning an explicitly accepted leaf still checks its dates and server name.
        if !systemTrusted {
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
            SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            guard SecTrustEvaluateWithError(trust, nil) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
        }
        if previous == fingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        guard let approval else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let request = ServerCertificateChallenge(sourceID: sourceID, host: host, port: port,
            subject: (SecCertificateCopySubjectSummary(leaf) as String?) ?? host,
            fingerprint: fingerprint, certificateDER: der, previouslyTrustedFingerprint: previous,
            reason: previous == nil ? "This server uses a certificate that macOS does not trust." : "The server certificate has changed.")
        Task {
            if await approval(request) {
                certificateStore.trust(fingerprint, sourceID: sourceID, host: host, port: port)
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let destination = request.url, Self.isValidURL(destination) else { completionHandler(nil); return }
        if response.url?.scheme?.lowercased() == "https", destination.scheme?.lowercased() == "http" {
            completionHandler(nil)
        } else { completionHandler(request) }
    }
}
