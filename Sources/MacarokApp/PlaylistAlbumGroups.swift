import Foundation
import MacarokCore

/// Display-only album headers for the active playlist. Entries keep their queue order, UUIDs, and
/// duplicates; only adjacent entries from the same source-specific album share a header.
enum PlaylistRow: Identifiable, Equatable {
    case header(PlaylistAlbumHeader)
    case entry(index: Int, item: QueueItem, layout: PlaylistEntryLayout)

    var id: String {
        switch self {
        case .header(let header): "header-\(header.firstEntryID.uuidString)"
        case .entry(_, let item, _): item.id.uuidString
        }
    }
}

enum PlaylistEntryLayout: Equatable {
    /// The compact presentation, also used for radio and entries without an album.
    case plain
    /// A lone album entry shows its own artwork instead of a header.
    case single
    /// Part of a group whose header precedes it.
    case grouped
}

struct PlaylistAlbumHeader: Equatable {
    let firstEntryID: UUID
    /// Queue offsets of every entry in this group, in order.
    let offsets: Range<Int>
    /// Supplies the actual source and cover for asynchronous artwork loading.
    let track: TrackRecord
    let album: String
    let artist: String
    let year: Int?
    let duration: Double
}

/// One row's share of a selection block. Rounded edges mark where a block starts and ends.
struct PlaylistRowHighlight: Equatable {
    enum Tone: Equatable {
        /// An album header band or a selected entry.
        case strong
        /// The body of a fully selected album, under its header band.
        case soft
    }
    let tone: Tone
    let roundsTop: Bool
    let roundsBottom: Bool
}

enum PlaylistAlbumGrouping {
    static func rows(_ queue: [QueueItem], grouped: Bool, isFlat: (TrackRecord) -> Bool) -> [PlaylistRow] {
        guard grouped else { return queue.enumerated().map { .entry(index: $0.offset, item: $0.element, layout: .plain) } }
        var rows: [PlaylistRow] = []
        rows.reserveCapacity(queue.count)
        var start = 0
        while start < queue.count {
            let first = queue[start].track
            guard !first.albumID.isEmpty, !isFlat(first) else {
                rows.append(.entry(index: start, item: queue[start], layout: .plain)); start += 1; continue
            }
            var end = start + 1
            while end < queue.count, queue[end].track.sourceID == first.sourceID, queue[end].track.albumID == first.albumID,
                  !isFlat(queue[end].track) { end += 1 }
            if end - start == 1 {
                rows.append(.entry(index: start, item: queue[start], layout: .single))
            } else {
                let tracks = queue[start..<end].map(\.track)
                rows.append(.header(PlaylistAlbumHeader(firstEntryID: queue[start].id, offsets: start..<end, track: first,
                    album: first.album.isEmpty ? "Unknown Album" : first.album,
                    artist: first.albumArtist.isEmpty ? first.artist : first.albumArtist,
                    year: first.year, duration: tracks.reduce(0) { $0 + $1.duration })))
                for index in start..<end { rows.append(.entry(index: index, item: queue[index], layout: .grouped)) }
            }
            start = end
        }
        return rows
    }

    /// Translates List offsets, which count headers, to queue offsets. Headers cannot be moved or deleted.
    static func queueOffsets(_ offsets: IndexSet, rows: [PlaylistRow]) -> IndexSet {
        IndexSet(offsets.compactMap { offset in
            guard rows.indices.contains(offset), case .entry(let index, _, _) = rows[offset] else { return nil }
            return index
        })
    }

    /// The playlist draws its own selection instead of the native accent band. A fully selected
    /// album reads as one block: a strong header band above a softer body. Other selected entries
    /// use the strong tone, and adjacent ones merge into a single rounded run.
    static func highlights(_ rows: [PlaylistRow], selected: Set<UUID>) -> [String: PlaylistRowHighlight] {
        guard !selected.isEmpty else { return [:] }
        var tones = [PlaylistRowHighlight.Tone?](repeating: nil, count: rows.count)
        for index in rows.indices where tones[index] == nil {
            switch rows[index] {
            case .header(let header):
                let body = rows.indices.dropFirst(index + 1).prefix(header.offsets.count)
                let complete = body.count == header.offsets.count && body.allSatisfy {
                    if case .entry(_, let item, _) = rows[$0] { return selected.contains(item.id) }
                    return false
                }
                guard complete else { continue }
                tones[index] = .strong
                for entry in body { tones[entry] = .soft }
            case .entry(_, let item, _):
                if selected.contains(item.id) { tones[index] = .strong }
            }
        }
        func joins(_ upper: Int, _ lower: Int) -> Bool {
            guard upper >= 0, lower < rows.count, let top = tones[upper], let bottom = tones[lower] else { return false }
            switch (rows[upper], top, rows[lower], bottom) {
            case (.header, .strong, .entry, .soft), (.entry, .soft, .entry, .soft), (.entry, .strong, .entry, .strong): return true
            default: return false
            }
        }
        var result: [String: PlaylistRowHighlight] = [:]
        for index in rows.indices {
            guard let tone = tones[index] else { continue }
            result[rows[index].id] = PlaylistRowHighlight(tone: tone, roundsTop: !joins(index - 1, index),
                                                          roundsBottom: !joins(index, index + 1))
        }
        return result
    }

    /// A drop position becomes the number of queue entries displayed before it.
    static func queueDestination(_ destination: Int, rows: [PlaylistRow]) -> Int {
        rows.prefix(max(0, min(destination, rows.count))).reduce(0) { count, row in
            if case .entry = row { return count + 1 }
            return count
        }
    }
}
