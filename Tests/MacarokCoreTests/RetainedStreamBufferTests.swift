import Foundation
import XCTest
@testable import MacarokCore

final class RetainedStreamBufferTests: XCTestCase {
    func testChunkReadsKeepNonzeroDataIndicesAndSeekAcrossBoundaries() {
        let first = Data(0..<100).dropFirst(17)
        let second = Data(100..<200).dropFirst(11)
        XCTAssertEqual(first.startIndex, 17)
        XCTAssertEqual(second.startIndex, 11)
        let buffer = RetainedStreamBuffer()
        buffer.reset(at: 1000)
        buffer.append(first); buffer.append(second)
        // Data concatenation can retain the first operand's nonzero indices. Keep the inputs
        // sliced, but rebase this independent oracle before using offset-based subranges.
        let expected = Data(Array(first) + Array(second))
        XCTAssertEqual(read(buffer, from: 1000, count: 1000), expected)
        XCTAssertEqual(read(buffer, from: 1080, count: 25), expected.subdata(in: 80..<105))
        XCTAssertEqual(read(buffer, from: 1001, count: 15), expected.subdata(in: 1..<16))
        XCTAssertEqual(read(buffer, from: 1080, count: 25), Data([97, 98, 99] + (111...132).map(UInt8.init)))
        XCTAssertEqual(buffer.count, expected.count)
    }

    func testEvictionOnlyReleasesConsumedChunksAndRetainsAbsoluteRanges() {
        let buffer = RetainedStreamBuffer()
        buffer.reset(at: 1000)
        buffer.append(Data(repeating: 1, count: 64))
        buffer.append(Data(repeating: 2, count: 64))
        buffer.makeSpace(for: 64, before: 1063, capacity: 128)
        XCTAssertEqual(buffer.count, 128, "A partially consumed chunk cannot be released or copied away.")
        buffer.makeSpace(for: 64, before: 1064, capacity: 128)
        XCTAssertEqual(buffer.startOffset, 1064)
        XCTAssertEqual(buffer.count, 64)
        buffer.append(Data(repeating: 3, count: 64))
        XCTAssertEqual(read(buffer, from: 1064, count: 128), Data(repeating: 2, count: 64) + Data(repeating: 3, count: 64))
        XCTAssertFalse(buffer.contains(1000))
        buffer.reset(at: 4000)
        XCTAssertFalse(buffer.contains(4000))
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.endOffset, 4000)
    }

    private func read(_ buffer: RetainedStreamBuffer, from offset: UInt64, count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let copied = bytes.withUnsafeMutableBufferPointer { buffer.read(into: $0.baseAddress!, from: offset, maxLength: count) }
        return Data(bytes.prefix(copied))
    }
}
