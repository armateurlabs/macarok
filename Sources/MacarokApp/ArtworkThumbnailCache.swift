import CoreGraphics
import Foundation
import ImageIO

/// CGImage is immutable; ownership may cross executors without moving an AppKit image or its drawing state.
struct ArtworkThumbnail: @unchecked Sendable {
    let cgImage: CGImage
    var memoryCost: Int { cgImage.bytesPerRow * cgImage.height }
}

/// Coalesces thumbnail requests and bounds ImageIO work independently of Swift's cooperative executor.
actor ArtworkThumbnailCache {
    static let shared = ArtworkThumbnailCache()
    private let cache = NSCache<NSString, ThumbnailEntry>()
    private let decoder: ThumbnailDecoder
    private var inFlight: [String: Task<ArtworkThumbnail?, Never>] = [:]

    init(maximumConcurrentDecodes: Int = 3, costLimit: Int = 64 * 1024 * 1024,
         decode: @escaping @Sendable (URL, Int) -> ArtworkThumbnail? = { ArtworkThumbnailCache.decodeImage(at: $0, pixelSize: $1) }) {
        decoder = ThumbnailDecoder(maximumConcurrentDecodes: maximumConcurrentDecodes, decode: decode)
        cache.totalCostLimit = max(1, costLimit)
        cache.countLimit = 256
    }

    func image(at path: String, revision: Int = 0, pixelSize: Int = 512) async -> ArtworkThumbnail? {
        guard !path.isEmpty, !Task.isCancelled else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let pixels = max(1, min(512, pixelSize))
        let key = "\(revision):\(pixels):\(url.path)"
        if let entry = cache.object(forKey: key as NSString) { return entry.thumbnail }
        if let pending = inFlight[key] {
            let thumbnail = await pending.value
            return Task.isCancelled ? nil : thumbnail
        }
        let worker = decoder
        let pending = Task.detached(priority: .utility) { await worker.image(at: url, pixelSize: pixels) }
        inFlight[key] = pending
        let thumbnail = await pending.value
        inFlight.removeValue(forKey: key)
        if let thumbnail { cache.setObject(ThumbnailEntry(thumbnail), forKey: key as NSString, cost: thumbnail.memoryCost) }
        return Task.isCancelled ? nil : thumbnail
    }

    private nonisolated static func decodeImage(at url: URL, pixelSize: Int) -> ArtworkThumbnail? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return ArtworkThumbnail(cgImage: image)
        }
    }
}

private final class ThumbnailEntry: NSObject {
    let thumbnail: ArtworkThumbnail
    init(_ thumbnail: ArtworkThumbnail) { self.thumbnail = thumbnail }
}

private final class ThumbnailDecoder: @unchecked Sendable {
    private let queue: OperationQueue
    private let decode: @Sendable (URL, Int) -> ArtworkThumbnail?

    init(maximumConcurrentDecodes: Int, decode: @escaping @Sendable (URL, Int) -> ArtworkThumbnail?) {
        queue = OperationQueue()
        queue.name = "Macarok.ArtworkThumbnails"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = max(1, min(3, maximumConcurrentDecodes))
        self.decode = decode
    }

    func image(at url: URL, pixelSize: Int) async -> ArtworkThumbnail? {
        await withCheckedContinuation { continuation in
            queue.addOperation { [decode] in continuation.resume(returning: decode(url, pixelSize)) }
        }
    }
}
