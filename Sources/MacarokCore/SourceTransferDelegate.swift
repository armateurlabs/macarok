import Foundation

/// The session's serial delegate queue owns the mutable state of each registered transfer.
final class SourceTransferDelegate: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private weak var owner: SourceTransport?
    private let lock = NSLock()
    private var streams: [Int: StreamHandler] = [:]
    private var downloads: [Int: DownloadHandler] = [:]

    init(owner: SourceTransport) { self.owner = owner }

    func register(_ task: URLSessionDataTask,
                  response: @escaping @Sendable (HTTPURLResponse) throws -> Void,
                  data: @escaping @Sendable (Data) throws -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        streams[task.taskIdentifier] = StreamHandler(response: response, data: data, completion: completion)
    }

    func register(_ task: URLSessionDownloadTask, destination: URL,
                  progress: (@Sendable (Int64, Int64?) -> Void)?,
                  completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        lock.lock(); defer { lock.unlock() }
        downloads[task.taskIdentifier] = DownloadHandler(destination: destination, progress: progress, completion: completion)
    }

    private func stream(_ task: URLSessionTask) -> StreamHandler? {
        lock.lock(); defer { lock.unlock() }; return streams[task.taskIdentifier]
    }
    private func download(_ task: URLSessionTask) -> DownloadHandler? {
        lock.lock(); defer { lock.unlock() }; return downloads[task.taskIdentifier]
    }

    func cancelStreams() {
        lock.lock(); let pending = Array(streams.values); streams.removeAll(); lock.unlock()
        // Wake a blocked consumer/producer before cancelling the session's serial delegate queue.
        pending.forEach { $0.complete(CancellationError()) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let handler = stream(dataTask) else { completionHandler(.cancel); return }
        do {
            guard let response = response as? HTTPURLResponse else { throw SourceNetworkError.invalidResponse }
            guard (200...299).contains(response.statusCode) else { throw SourceNetworkError.httpStatus(response.statusCode) }
            try handler.response(response)
            completionHandler(.allow)
        } catch {
            handler.error = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handler = stream(dataTask), handler.error == nil else { return }
        do { try handler.data(data) }
        catch { handler.error = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let stream = streams.removeValue(forKey: task.taskIdentifier)
        let download = downloads.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if let stream { stream.complete(stream.error ?? error) }
        if let download {
            if let error { download.completion(.failure(error)) }
            else { download.completion(download.result ?? .failure(SourceNetworkError.invalidResponse)) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        download(downloadTask)?.progress?(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let handler = download(downloadTask) else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else { throw SourceNetworkError.invalidResponse }
            guard (200...299).contains(response.statusCode) else { throw SourceNetworkError.httpStatus(response.statusCode) }
            let manager = FileManager.default
            try manager.createDirectory(at: handler.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: handler.destination.path) {
                _ = try manager.replaceItemAt(handler.destination, withItemAt: location)
            } else { try manager.moveItem(at: location, to: handler.destination) }
            handler.result = .success(handler.destination)
        } catch { handler.result = .failure(error) }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let owner else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        owner.handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let owner else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        owner.handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let owner else { completionHandler(nil); return }
        owner.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }

    private final class StreamHandler {
        let response: @Sendable (HTTPURLResponse) throws -> Void
        let data: @Sendable (Data) throws -> Void
        let completion: @Sendable (Error?) -> Void
        var error: Error?
        private let completionLock = NSLock()
        private var completed = false
        init(response: @escaping @Sendable (HTTPURLResponse) throws -> Void,
             data: @escaping @Sendable (Data) throws -> Void,
             completion: @escaping @Sendable (Error?) -> Void) {
            self.response = response; self.data = data; self.completion = completion
        }
        func complete(_ error: Error?) {
            completionLock.lock()
            guard !completed else { completionLock.unlock(); return }
            completed = true; completionLock.unlock()
            completion(error)
        }
    }
    private final class DownloadHandler {
        let destination: URL
        let progress: (@Sendable (Int64, Int64?) -> Void)?
        let completion: @Sendable (Result<URL, Error>) -> Void
        var result: Result<URL, Error>?
        init(destination: URL, progress: (@Sendable (Int64, Int64?) -> Void)?,
             completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
            self.destination = destination; self.progress = progress; self.completion = completion
        }
    }
}

/// Handles cancellation arriving before URLSession has installed the asynchronous task.
final class SourceTransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func install(_ task: URLSessionTask) {
        lock.lock(); self.task = task; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { task.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
}
