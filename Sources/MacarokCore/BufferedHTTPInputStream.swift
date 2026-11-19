import Foundation
import os

public struct StreamBufferSnapshot: Sendable {
    public let bufferedBytes: Int
    public let targetBytes: Int
    public let totalBytes: Int64?
    public let offset: UInt64
    public let isBuffering: Bool
    public let isFinished: Bool
    /// Only bytes currently retained and reusable, not a cumulative downloaded prefix.
    public let retainedRanges: [Range<UInt64>]
    public let capacityBytes: Int
    public let underrunCount: Int
    public let readerWaitDuration: TimeInterval
    /// Automatic reconnections after transient network failures during this stream.
    public let resumeCount: Int

    public init(bufferedBytes: Int, targetBytes: Int, totalBytes: Int64?, offset: UInt64,
                isBuffering: Bool, isFinished: Bool, retainedRanges: [Range<UInt64>] = [],
                capacityBytes: Int = 0, underrunCount: Int = 0, readerWaitDuration: TimeInterval = 0, resumeCount: Int = 0) {
        self.bufferedBytes = bufferedBytes; self.targetBytes = targetBytes; self.totalBytes = totalBytes
        self.offset = offset; self.isBuffering = isBuffering; self.isFinished = isFinished
        self.retainedRanges = retainedRanges; self.capacityBytes = capacityBytes
        self.underrunCount = underrunCount; self.readerWaitDuration = readerWaitDuration; self.resumeCount = resumeCount
    }
}

/// A seekable byte stream for libVLC using the same transport and certificate policy as its source.
/// The decoder's reader thread can block; HTTP production and certificate approval stay asynchronous.
public final class BufferedHTTPInputStream: InputStream, @unchecked Sendable {
    private let remoteURL: URL
    private let transport: SourceTransport
    private let live: Bool
    private let onTitle: (@Sendable (String) -> Void)?
    private let onStationInfo: (@Sendable (RadioStreamInfo) -> Void)?
    private var titleUpdates: [ICYTitleUpdate] = []
    private let condition = NSCondition()
    private let requestedBufferSeconds: Double?
    private let durationHint: Double?
    private let fallbackCapacity: Int
    private var capacity: Int
    private var targetBytes = 128 * 1024
    private let buffer = RetainedStreamBuffer()
    private var offset: UInt64 = 0
    private var generation = 0
    private var ended = false
    private var closed = false
    private var failure: Error?
    private var producer: URLSessionDataTask?
    private var opened = false
    private var priming = true
    private var length: Int64?
    private var seekSupported: Bool?
    private var hasRead = false
    private var underruns = 0
    /// Consecutive reconnections without new audio; reset once bytes arrive again.
    private var resumeAttempts = 0
    private var resumes = 0
    /// Delay before each reconnection after a transient network failure.
    public static let defaultResumeDelays: [TimeInterval] = [0.5, 1, 2, 4]
    private let resumeDelays: [TimeInterval]
    private var readerWaitDuration: TimeInterval = 0
    private let signposter = OSSignposter(subsystem: "labs.armateur.Macarok", category: "Playback HTTP")

    public init(url: URL, transport: SourceTransport, bufferBytes: Int = 4 * 1024 * 1024,
                bufferSeconds: Double? = nil, durationHint: Double? = nil, live: Bool = false,
                resumeDelays: [TimeInterval] = BufferedHTTPInputStream.defaultResumeDelays,
                onTitle: (@Sendable (String) -> Void)? = nil,
                onStationInfo: (@Sendable (RadioStreamInfo) -> Void)? = nil) {
        remoteURL = url
        self.resumeDelays = resumeDelays
        self.transport = transport
        self.live = live; self.onTitle = onTitle; self.onStationInfo = onStationInfo
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
            isFinished: ended && available == 0,
            retainedRanges: buffer.count > 0 ? [buffer.startOffset..<buffer.endOffset] : [],
            capacityBytes: capacity, underrunCount: underruns, readerWaitDuration: readerWaitDuration, resumeCount: resumes)
    }

    /// Nil until the server response establishes whether byte-range requests are supported.
    public var supportsSeeking: Bool? {
        condition.lock(); defer { condition.unlock() }
        return closed ? false : seekSupported
    }

    private var available: Int { Int(buffer.endOffset - offset) }

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
        buffer.reset(at: offset); titleUpdates.removeAll(); condition.broadcast()
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
        if !closed && available == 0 && !ended && failure == nil {
            priming = true
            if hasRead { underruns += 1 }
        }
        if !closed && !ended && failure == nil && (available == 0 || (priming && available < targetBytes)) {
            let interval = signposter.beginInterval("StreamBufferWait")
            let began = ProcessInfo.processInfo.systemUptime
            while !closed && !ended && failure == nil && (available == 0 || (priming && available < targetBytes)) {
                condition.wait()
            }
            readerWaitDuration += ProcessInfo.processInfo.systemUptime - began
            signposter.endInterval("StreamBufferWait", interval)
        }
        if closed { return 0 }
        if available == 0 { return failure == nil ? 0 : -1 }
        priming = false; hasRead = true
        let count = buffer.read(into: destination, from: offset, maxLength: len)
        offset += UInt64(count)
        while let update = titleUpdates.first, update.audioOffset <= offset {
            titleUpdates.removeFirst()
            titles.append(update.title)
        }
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
        hasRead = false // A requested seek starts a new prime, not a spontaneous decoder underrun.
        // VLC often seeks around a nearby timestamp while decoding a compressed frame. Reuse those
        // retained bytes instead of cancelling a good request and waiting for another full prime.
        if buffer.contains(newOffset) {
            offset = newOffset; priming = false
            condition.broadcast(); condition.unlock()
            return true
        }
        let oldProducer = producer
        producer = nil; generation += 1
        let current = generation
        offset = newOffset; buffer.reset(at: newOffset)
        ended = length.map { newOffset == UInt64($0) } ?? false
        failure = nil; priming = true; resumeAttempts = 0
        let atEnd = ended
        condition.broadcast(); condition.unlock()
        oldProducer?.cancel()
        if !atEnd { begin(offset: newOffset, generation: current) }
        return true
    }

    public override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    public override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}

    private func begin(offset requestedOffset: UInt64, generation requestedGeneration: Int) {
        var request = URLRequest(url: remoteURL)
        if !live { request.setValue("bytes=\(requestedOffset)-", forHTTPHeaderField: "Range") }
        else {
            request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
            request.setValue("Macarok/0.1 (macOS; https://github.com/armateurlabs/macarok)", forHTTPHeaderField: "User-Agent")
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let state = Producer(stream: self, offset: requestedOffset, generation: requestedGeneration)
        do {
            let task = try transport.startPlaybackStream(for: request,
                onResponse: { try state.accept($0) }, onData: { try state.receive($0) }, onComplete: { state.complete($0) })
            condition.lock()
            if generation == requestedGeneration && !closed { producer = task; condition.unlock(); task.resume() }
            else { condition.unlock(); task.cancel() }
        } catch { finish(error: error, generation: requestedGeneration) }
    }

    /// These callbacks are serialized by the playback session, independently of Swift tasks and UI work.
    private final class Producer: @unchecked Sendable {
        private weak var stream: BufferedHTTPInputStream?
        private let offset: UInt64
        private let generation: Int
        private var expectedBytes: UInt64?
        private var receivedBytes: UInt64 = 0
        private var decoder: ICYMetadataDecoder?
        init(stream: BufferedHTTPInputStream, offset: UInt64, generation: Int) {
            self.stream = stream; self.offset = offset; self.generation = generation
        }
        func accept(_ response: HTTPURLResponse) throws {
            guard let stream else { throw CancellationError() }
            expectedBytes = try stream.acceptResponse(response, requestedOffset: offset, generation: generation)
            if stream.live { stream.onStationInfo?(RadioStreamInfo(response: response)) }
            if stream.live, let raw = response.value(forHTTPHeaderField: "icy-metaint") {
                guard let interval = Int(raw) else { throw RadioError.invalidResponse }
                decoder = try ICYMetadataDecoder(interval: interval)
            }
        }
        func receive(_ data: Data) throws {
            guard let stream else { throw CancellationError() }
            receivedBytes += UInt64(data.count)
            if let expectedBytes, receivedBytes > expectedBytes { throw StreamFailure.invalidRange }
            // Bound chunk size even if URLSession coalesces several network reads into one callback.
            var start = data.startIndex
            while start < data.endIndex {
                let end = data.index(start, offsetBy: min(64 * 1024, data.distance(from: start, to: data.endIndex)))
                let chunk = start == data.startIndex && end == data.endIndex ? data : data.subdata(in: start..<end)
                let content = decoder?.consume(chunk) ?? (audio: chunk, updates: [])
                guard stream.enqueue(content.audio, updates: content.updates, generation: generation) else { throw CancellationError() }
                start = end
            }
        }
        func complete(_ error: Error?) {
            guard let stream else { return }
            let error = error ?? expectedBytes.flatMap { receivedBytes == $0 ? nil : StreamFailure.truncatedResponse }
            stream.finish(error: error, generation: generation)
        }
    }

    /// Wait only on the dedicated HTTP delegate thread. Decoder reads, seeks, and close wake it directly.
    private func enqueue(_ chunk: Data, updates: [ICYTitleUpdate], generation expected: Int) -> Bool {
        condition.lock()
        let task = producer
        var suspended = false
        defer { condition.unlock(); if suspended { task?.resume() } }
        while generation == expected && !closed && !ended && failure == nil {
            buffer.makeSpace(for: chunk.count, before: offset, capacity: capacity)
            if buffer.count + chunk.count <= capacity {
                buffer.append(chunk)
                resumeAttempts = 0
                titleUpdates.append(contentsOf: updates)
                if titleUpdates.count > 512 { titleUpdates.removeFirst(titleUpdates.count - 512) }
                condition.broadcast()
                return true
            }
            if !suspended { task?.suspend(); suspended = true }
            condition.wait()
        }
        return false
    }

    private func finish(error: Error?, generation expected: Int) {
        condition.lock(); defer { condition.unlock() }
        guard generation == expected && !closed else { return }
        // A dropped connection resumes from the first missing byte instead of ending the track early.
        // The decoder keeps waiting on the condition meanwhile, exactly as during ordinary buffering.
        let resumeAt = buffer.count > 0 ? buffer.endOffset : offset
        if let error, !live, seekSupported == true, Self.isTransient(error), resumeAttempts < resumeDelays.count,
           length.map({ resumeAt < UInt64($0) }) ?? true {
            let delay = resumeDelays[resumeAttempts]
            resumeAttempts += 1; resumes += 1
            generation += 1; producer = nil
            let next = generation
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.begin(offset: resumeAt, generation: next)
            }
            return
        }
        failure = error; ended = true; producer = nil
        if error != nil && priming { buffer.reset(at: offset) }
        condition.broadcast()
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

    /// Failures worth retrying: the connection dropped or stalled, or the server cut the transfer short.
    static func isTransient(_ error: Error) -> Bool {
        if case StreamFailure.truncatedResponse = error { return true }
        if case SourceNetworkError.httpStatus(let status) = error { return [408, 429, 500, 502, 503, 504].contains(status) }
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet,
                NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
                NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff].contains(error.code)
    }

    /// VLCKit reports an unknown size for every NSInputStream. libVLC's FLAC and Ogg demuxers need the
    /// byte length to seek, so these formats must reach VLC another way to remain seekable.
    public static func requiresKnownByteLength(format: String, url: URL) -> Bool {
        let formats: Set<String> = ["flac", "fla", "ogg", "oga", "ogx", "opus", "spx"]
        return formats.contains(format.lowercased()) || formats.contains(url.pathExtension.lowercased())
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
