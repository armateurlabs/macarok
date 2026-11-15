import Foundation

public struct StreamBufferSnapshot: Sendable {
    public let bufferedBytes: Int
    public let targetBytes: Int
    public let totalBytes: Int64?
    public let offset: UInt64
    public let isBuffering: Bool
    public let isFinished: Bool
}

/// A seekable byte stream for libVLC using the same transport and certificate policy as its source.
/// The decoder's reader thread can block; HTTP production and certificate approval stay asynchronous.
public final class BufferedHTTPInputStream: InputStream, @unchecked Sendable {
    private let remoteURL: URL
    private let transport: SourceTransport
    private let live: Bool
    private let onTitle: (@Sendable (String) -> Void)?
    private var titleUpdates: [ICYTitleUpdate] = []
    private let condition = NSCondition()
    private let requestedBufferSeconds: Double?
    private let durationHint: Double?
    private let fallbackCapacity: Int
    private var capacity: Int
    private var targetBytes = 128 * 1024
    private var buffer = Data()
    private var readCursor = 0
    private var offset: UInt64 = 0
    private var generation = 0
    private var ended = false
    private var closed = false
    private var failure: Error?
    private var producer: Task<Void, Never>?
    private var opened = false
    private var priming = true
    private var length: Int64?
    private var seekSupported: Bool?

    public init(url: URL, transport: SourceTransport, bufferBytes: Int = 4 * 1024 * 1024,
                bufferSeconds: Double? = nil, durationHint: Double? = nil, live: Bool = false,
                onTitle: (@Sendable (String) -> Void)? = nil) {
        remoteURL = url
        self.transport = transport
        self.live = live; self.onTitle = onTitle
        requestedBufferSeconds = bufferSeconds.flatMap { $0.isFinite ? min(120, max(1, $0)) : nil }
        self.durationHint = durationHint.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        fallbackCapacity = max(256 * 1024, min(bufferBytes, 256 * 1024 * 1024))
        capacity = fallbackCapacity
        super.init(data: Data())
    }

    public var snapshot: StreamBufferSnapshot {
        condition.lock(); defer { condition.unlock() }
        return StreamBufferSnapshot(bufferedBytes: available, targetBytes: targetBytes,
            totalBytes: length, offset: offset, isBuffering: priming && !ended && !closed && failure == nil,
            isFinished: ended && available == 0)
    }

    private var available: Int { buffer.count - readCursor }

    public override func open() {
        condition.lock()
        guard !opened, !closed else { condition.unlock(); return }
        opened = true
        let current = generation
        condition.unlock()
        begin(offset: 0, generation: current)
    }

    public override func close() {
        condition.lock()
        closed = true; generation += 1
        let task = producer; producer = nil
        buffer.removeAll(); titleUpdates.removeAll(); readCursor = 0; condition.broadcast()
        condition.unlock()
        task?.cancel()
    }

    public override var streamStatus: Stream.Status {
        condition.lock(); defer { condition.unlock() }
        if closed { return .closed }
        if failure != nil && available == 0 { return .error }
        if ended && available == 0 { return .atEnd }
        return opened ? .open : .notOpen
    }

    public override var streamError: Error? {
        condition.lock(); defer { condition.unlock() }
        return failure
    }

    public override var hasBytesAvailable: Bool {
        condition.lock(); defer { condition.unlock() }
        return !closed && (available > 0 || (!ended && failure == nil && opened))
    }

    public override func read(_ destination: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard len > 0 else { return 0 }
        condition.lock()
        var titles: [String] = []
        defer { condition.unlock(); for title in titles { onTitle?(title) } }
        guard opened else { return -1 }
        if available == 0 && !ended && failure == nil { priming = true }
        while !closed && !ended && failure == nil && (available == 0 || (priming && available < targetBytes)) {
            condition.wait()
        }
        if closed { return 0 }
        if available == 0 { return failure == nil ? 0 : -1 }
        priming = false
        let count = min(len, available)
        // Removing a consumed prefix can leave Data with a nonzero startIndex.
        let start = buffer.index(buffer.startIndex, offsetBy: readCursor)
        let end = buffer.index(start, offsetBy: count)
        buffer.copyBytes(to: destination, from: start..<end)
        readCursor += count
        offset += UInt64(count)
        while let update = titleUpdates.first, update.audioOffset <= offset {
            titleUpdates.removeFirst()
            titles.append(update.title)
        }
        if readCursor == buffer.count { buffer.removeAll(keepingCapacity: true); readCursor = 0 }
        else if readCursor >= 1024 * 1024 { buffer.removeFirst(readCursor); readCursor = 0 }
        condition.broadcast()
        return count
    }

    public override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>) -> Bool { false }

    public override func property(forKey key: Stream.PropertyKey) -> Any? {
        condition.lock(); defer { condition.unlock() }
        if key == .fileCurrentOffsetKey { return NSNumber(value: offset) }
        if key.rawValue == "NSStreamFileSizeKey", let length { return NSNumber(value: length) }
        return nil
    }

    public override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool {
        guard !live, key == .fileCurrentOffsetKey, let number = property as? NSNumber,
              number.doubleValue.isFinite, number.int64Value >= 0 else { return false }
        let newOffset = number.uint64Value
        condition.lock()
        guard !closed, opened, length.map({ newOffset <= UInt64($0) }) ?? true else { condition.unlock(); return false }
        if newOffset == offset { condition.unlock(); return true }
        if seekSupported == false { condition.unlock(); return false }
        let oldProducer = producer
        producer = nil; generation += 1
        let current = generation
        offset = newOffset; buffer.removeAll(keepingCapacity: true); readCursor = 0
        ended = length.map { newOffset == UInt64($0) } ?? false
        failure = nil; priming = true
        let atEnd = ended
        condition.broadcast(); condition.unlock()
        oldProducer?.cancel()
        if !atEnd { begin(offset: newOffset, generation: current) }
        return true
    }

    public override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    public override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}

    private func begin(offset requestedOffset: UInt64, generation requestedGeneration: Int) {
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: self.remoteURL)
                if !self.live { request.setValue("bytes=\(requestedOffset)-", forHTTPHeaderField: "Range") }
                else {
                    request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
                    request.setValue("Macarok/0.1 (macOS; https://github.com/armateurlabs/macarok)", forHTTPHeaderField: "User-Agent")
                }
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let (bytes, response) = try await self.transport.bytes(for: request)
                defer { bytes.task.cancel() }
                let expectedBytes = try self.acceptResponse(response, requestedOffset: requestedOffset, generation: requestedGeneration)
                var decoder: ICYMetadataDecoder?
                if self.live, let raw = response.value(forHTTPHeaderField: "icy-metaint") {
                    guard let interval = Int(raw) else { throw RadioError.invalidResponse }
                    decoder = try ICYMetadataDecoder(interval: interval)
                }
                var receivedBytes: UInt64 = 0
                var chunk = Data(); chunk.reserveCapacity(64 * 1024)
                for try await byte in bytes {
                    try Task.checkCancellation()
                    receivedBytes += 1
                    if let expectedBytes, receivedBytes > expectedBytes { throw StreamFailure.invalidRange }
                    chunk.append(byte)
                    if chunk.count >= 64 * 1024 {
                        let content = decoder?.consume(chunk) ?? (audio: chunk, updates: [])
                        guard await self.enqueue(content.audio, updates: content.updates, task: bytes.task, generation: requestedGeneration) else { return }
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if let expectedBytes, receivedBytes != expectedBytes { throw StreamFailure.truncatedResponse }
                if !chunk.isEmpty {
                    let content = decoder?.consume(chunk) ?? (audio: chunk, updates: [])
                    _ = await self.enqueue(content.audio, updates: content.updates, task: bytes.task, generation: requestedGeneration)
                }
                self.finish(error: nil, generation: requestedGeneration)
            } catch is CancellationError { }
            catch { self.finish(error: error, generation: requestedGeneration) }
        }
        condition.lock()
        if generation == requestedGeneration && !closed { producer = task } else { task.cancel() }
        condition.unlock()
    }

    private enum EnqueueResult { case accepted, full, obsolete }

    private func tryEnqueue(_ chunk: Data, updates: [ICYTitleUpdate], generation expected: Int) -> EnqueueResult {
        condition.lock(); defer { condition.unlock() }
        guard generation == expected && !closed else { return .obsolete }
        guard available < capacity else { return .full }
        if readCursor > 0 && buffer.count + chunk.count > capacity + 1024 * 1024 {
            buffer.removeFirst(readCursor); readCursor = 0
        }
        buffer.append(chunk); condition.broadcast()
        titleUpdates.append(contentsOf: updates)
        // Bound metadata as well as audio, including broadcasts with unusually small ICY intervals.
        if titleUpdates.count > 512 { titleUpdates.removeFirst(titleUpdates.count - 512) }
        return .accepted
    }

    private func enqueue(_ chunk: Data, updates: [ICYTitleUpdate] = [], task: URLSessionTask, generation expected: Int) async -> Bool {
        var suspended = false
        defer { if suspended { task.resume() } }
        while !Task.isCancelled {
            switch tryEnqueue(chunk, updates: updates, generation: expected) {
            case .accepted: return true
            case .obsolete: return false
            case .full:
                if !suspended { task.suspend(); suspended = true }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
            }
        }
        return false
    }

    private func finish(error: Error?, generation expected: Int) {
        condition.lock(); defer { condition.unlock() }
        guard generation == expected && !closed else { return }
        failure = error; ended = true; condition.broadcast()
    }

    private func acceptResponse(_ response: HTTPURLResponse, requestedOffset: UInt64, generation expected: Int) throws -> UInt64? {
        if live {
            guard response.statusCode == 200 else { throw RadioError.invalidResponse }
            let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if type.contains("mpegurl") || response.url?.pathExtension.lowercased() == "m3u8" { throw RadioError.unsupportedHLS }
        }
        guard response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            throw StreamFailure.encodedResponse
        }
        var total: Int64?
        let expectedBytes: UInt64?
        if response.statusCode == 206 {
            guard let header = response.value(forHTTPHeaderField: "Content-Range"), let range = Self.contentRange(header), range.start == requestedOffset else {
                throw StreamFailure.invalidRange
            }
            // An open-ended request must cover the rest of the original representation.
            if let total = range.total, range.end != UInt64(total - 1) { throw StreamFailure.invalidRange }
            total = range.total
            expectedBytes = range.end - range.start + 1
        } else {
            guard response.statusCode == 200, requestedOffset == 0 else { throw StreamFailure.rangeUnsupported }
            if response.expectedContentLength >= 0 { total = response.expectedContentLength }
            expectedBytes = total.map(UInt64.init)
        }
        condition.lock(); defer { condition.unlock() }
        guard generation == expected && !closed else { return expectedBytes }
        length = live ? nil : total ?? length
        seekSupported = !live && (response.statusCode == 206 || response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes")
        let target: Double
        if let length, let durationHint {
            target = Double(length) / durationHint * (requestedBufferSeconds ?? 2)
        } else if let requestedBufferSeconds {
            // Unknown-length streams use a conservative 192 kbit/s estimate until their format is known.
            target = requestedBufferSeconds * 24_000
        } else { target = 128 * 1024 }
        targetBytes = max(1, min(Int(min(target, 256 * 1024 * 1024)), 256 * 1024 * 1024))
        if let remaining = length.map({ max(0, $0 - Int64(requestedOffset)) }) { targetBytes = min(targetBytes, max(1, Int(remaining))) }
        capacity = max(fallbackCapacity, min(256 * 1024 * 1024 + 64 * 1024, targetBytes + 64 * 1024))
        condition.broadcast()
        return live ? nil : expectedBytes
    }

    static func contentRange(_ value: String) -> (start: UInt64, end: UInt64, total: Int64?)? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let sizes = parts[1].split(separator: "/", maxSplits: 1)
        let bounds = sizes.first?.split(separator: "-", maxSplits: 1) ?? []
        guard sizes.count == 2, bounds.count == 2, let start = UInt64(bounds[0]), let end = UInt64(bounds[1]),
              end >= start, end < UInt64(Int64.max) else { return nil }
        let total = sizes[1] == "*" ? nil : Int64(sizes[1])
        if let total, total <= 0 || UInt64(total) <= end { return nil }
        guard sizes[1] == "*" || total != nil else { return nil }
        return (start, end, total)
    }

    public enum StreamFailure: LocalizedError {
        case rangeUnsupported
        case invalidRange
        case truncatedResponse
        case encodedResponse
        public var errorDescription: String? {
            switch self {
            case .rangeUnsupported: return "This server does not support seeking in the original stream."
            case .invalidRange: return "The server returned an incorrect audio byte range."
            case .truncatedResponse: return "The server ended the audio transfer before the requested bytes were received."
            case .encodedResponse: return "The server compressed the original audio byte stream, so it cannot be played safely."
            }
        }
    }
}
