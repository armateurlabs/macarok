import Foundation

/// A bounded chain of immutable network chunks. Releasing consumed chunks never copies audio bytes.
/// The owning stream serializes access with its condition lock.
final class RetainedStreamBuffer {
    private final class Chunk {
        let data: Data
        let start: UInt64
        var next: Chunk?
        var end: UInt64 { start + UInt64(data.count) }
        init(_ data: Data, at start: UInt64) { self.data = data; self.start = start }
    }
    private var head: Chunk?
    private var tail: Chunk?
    private var reader: Chunk?
    private(set) var startOffset: UInt64 = 0
    private(set) var endOffset: UInt64 = 0
    private(set) var count = 0

    deinit { reset(at: endOffset) }

    func reset(at offset: UInt64) {
        reader = nil; tail = nil
        while let chunk = head { head = chunk.next; chunk.next = nil }
        startOffset = offset; endOffset = offset; count = 0
    }

    func contains(_ offset: UInt64) -> Bool {
        count > 0 && offset >= startOffset && offset <= endOffset
    }

    /// Only wholly consumed chunks are released. A partially consumed head stays available for seeks.
    func makeSpace(for incomingBytes: Int, before readOffset: UInt64, capacity: Int) {
        while count + incomingBytes > capacity, let chunk = head, chunk.end <= readOffset {
            head = chunk.next; chunk.next = nil
            if reader === chunk { reader = head }
            count -= chunk.data.count
        }
        if let head { startOffset = head.start }
        else { tail = nil; startOffset = endOffset }
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let chunk = Chunk(data, at: endOffset)
        if let tail { tail.next = chunk } else { head = chunk; startOffset = endOffset }
        tail = chunk; endOffset = chunk.end; count += data.count
    }

    func read(into destination: UnsafeMutablePointer<UInt8>, from offset: UInt64, maxLength: Int) -> Int {
        guard offset >= startOffset, offset < endOffset, maxLength > 0 else { return 0 }
        var chunk = reader
        if chunk == nil || offset < chunk!.start || offset >= chunk!.end {
            chunk = head
            while let current = chunk, current.end <= offset { chunk = current.next }
        }
        let requested = min(maxLength, Int(endOffset - offset))
        var copied = 0
        while let current = chunk, copied < requested {
            let withinChunk = Int(offset + UInt64(copied) - current.start)
            let count = min(requested - copied, current.data.count - withinChunk)
            let start = current.data.index(current.data.startIndex, offsetBy: withinChunk)
            let end = current.data.index(start, offsetBy: count)
            current.data.copyBytes(to: destination.advanced(by: copied), from: start..<end)
            copied += count
            reader = current
            chunk = current.next
        }
        return copied
    }
}
