import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import MacarokApp

final class ArtworkThumbnailCacheTests: XCTestCase {
    func testImageIOProducesBoundedThumbnailsAndRejectsMissingOrMalformedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacarokThumbnailTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.png")
        let image = try makeImage(width: 1200, height: 2400, red: 1, blue: 0)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let cache = ArtworkThumbnailCache()
        let loaded = await cache.image(at: url.path, pixelSize: 300)
        let thumbnail = try XCTUnwrap(loaded)
        XCTAssertEqual(thumbnail.cgImage.height, 300)
        XCTAssertEqual(thumbnail.cgImage.width, 150)
        XCTAssertLessThanOrEqual(thumbnail.memoryCost, 300 * 300 * 8)
        let loadedCapped = await cache.image(at: url.path, pixelSize: 8000)
        let capped = try XCTUnwrap(loadedCapped)
        XCTAssertEqual(capped.cgImage.height, 512)
        let missing = await cache.image(at: directory.appendingPathComponent("missing.png").path)
        XCTAssertNil(missing)
        let invalid = directory.appendingPathComponent("invalid.png")
        try Data("invalid image bytes".utf8).write(to: invalid)
        let malformed = await cache.image(at: invalid.path)
        XCTAssertNil(malformed)
    }

    func testIdenticalRequestsCoalesceAndRevisionAndPixelSizeCreateSeparateEntries() async throws {
        let probe = ThumbnailProbe(image: try makeImage(width: 8, height: 8, red: 1, blue: 0), delay: 0.04)
        let cache = ArtworkThumbnailCache(decode: { url, size in probe.decode(url, size) })
        let images = await withTaskGroup(of: ArtworkThumbnail?.self) { group in
            for _ in 0..<12 { group.addTask { await cache.image(at: "/synthetic/cover.png", revision: 3, pixelSize: 256) } }
            var values: [ArtworkThumbnail?] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(images.compactMap { $0 }.count, 12)
        XCTAssertEqual(probe.calls, 1)
        _ = await cache.image(at: "/synthetic/cover.png", revision: 3, pixelSize: 256)
        XCTAssertEqual(probe.calls, 1)
        _ = await cache.image(at: "/synthetic/cover.png", revision: 4, pixelSize: 256)
        _ = await cache.image(at: "/synthetic/cover.png", revision: 4, pixelSize: 128)
        XCTAssertEqual(probe.calls, 3)
        XCTAssertFalse(probe.usedMainThread, "Image reads and decoding must run on the utility worker queue.")
    }

    func testDecodeConcurrencyIsBoundedOutsideTheMainThread() async throws {
        let probe = ThumbnailProbe(image: try makeImage(width: 8, height: 8, red: 1, blue: 0), delay: 0.04)
        let cache = ArtworkThumbnailCache(maximumConcurrentDecodes: 3, decode: { url, size in probe.decode(url, size) })
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<18 { group.addTask { _ = await cache.image(at: "/synthetic/\(index).png") } }
        }
        XCTAssertEqual(probe.calls, 18)
        XCTAssertGreaterThan(probe.maximumActive, 0)
        XCTAssertLessThanOrEqual(probe.maximumActive, 3)
        XCTAssertFalse(probe.usedMainThread)
    }

    func testLateOldRevisionCannotReplaceTheNewRevisionAndCancellationDoesNotCancelSharedWork() async throws {
        let red = try makeImage(width: 8, height: 8, red: 1, blue: 0)
        let blue = try makeImage(width: 8, height: 8, red: 0, blue: 1)
        let gate = ThumbnailRevisionGate(old: red, new: blue)
        let cache = ArtworkThumbnailCache(decode: { _, _ in gate.decode() })
        let old = Task { await cache.image(at: "/synthetic/cover.png", revision: 1) }
        try await waitUntil { gate.calls == 1 }
        let same = Task { await cache.image(at: "/synthetic/cover.png", revision: 1) }
        old.cancel()
        let latest = await cache.image(at: "/synthetic/cover.png", revision: 2)
        XCTAssertTrue(latest?.cgImage === blue)
        gate.releaseOld()
        let cancelled = await old.value
        let shared = await same.value
        XCTAssertNil(cancelled)
        XCTAssertTrue(shared?.cgImage === red, "Cancelling one view must preserve a coalesced request still used by another view.")
        let cachedLatest = await cache.image(at: "/synthetic/cover.png", revision: 2)
        XCTAssertTrue(cachedLatest?.cgImage === blue)
        XCTAssertEqual(gate.calls, 2)
    }

    private func makeImage(width: Int, height: Int, red: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

}

private final class ThumbnailProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let image: CGImage
    private let delay: TimeInterval
    private var total = 0, active = 0, peak = 0
    private var onMain = false
    init(image: CGImage, delay: TimeInterval) { self.image = image; self.delay = delay }
    var calls: Int { lock.withLock { total } }
    var maximumActive: Int { lock.withLock { peak } }
    var usedMainThread: Bool { lock.withLock { onMain } }
    func decode(_ url: URL, _ size: Int) -> ArtworkThumbnail? {
        lock.withLock { total += 1; active += 1; peak = max(peak, active); onMain = onMain || Thread.isMainThread }
        Thread.sleep(forTimeInterval: delay)
        lock.withLock { active -= 1 }
        return ArtworkThumbnail(cgImage: image)
    }
}

private final class ThumbnailRevisionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let old: CGImage, new: CGImage
    private var count = 0
    init(old: CGImage, new: CGImage) { self.old = old; self.new = new }
    var calls: Int { lock.withLock { count } }
    func releaseOld() { gate.signal() }
    func decode() -> ArtworkThumbnail? {
        let ordinal = lock.withLock { count += 1; return count }
        if ordinal == 1 { _ = gate.wait(timeout: .now() + 5) }
        return ArtworkThumbnail(cgImage: ordinal == 1 ? old : new)
    }
}
