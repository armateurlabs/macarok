import Foundation
import MacarokCore

enum PodcastDate {
    /// Podcast import stores the publication time in `addedAt`; `year` is nil when the feed gave no date.
    static func publication(_ track: TrackRecord) -> Date? { track.year == nil ? nil : track.addedAt }

    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let day = calendar.startOfDay(for: date), today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if days > 1 && days < 7 { return date.formatted(style.weekday(.abbreviated)) }
        style = style.day().month(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return date.formatted(style)
    }

    static func short(_ track: TrackRecord, now: Date = Date()) -> String? { publication(track).map { short($0, now: now) } }

    static func remaining(_ seconds: Double) -> String {
        let minutes = max(1, Int((max(0, seconds) / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min left" : "\(minutes) min left"
    }
}

enum PodcastEpisodeState: Equatable, Sendable {
    case unplayed
    case inProgress(position: Double, remaining: Double)
    case played

    var isUnplayed: Bool { self == .unplayed }
    var isInProgress: Bool { if case .inProgress = self { true } else { false } }
}

enum PodcastEpisodeFilter: String, CaseIterable, Identifiable {
    case all, unplayed, downloaded
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct PodcastShowSummary: Identifiable, Equatable {
    let id: String
    let title: String
    let latestEpisode: TrackRecord?
    let episodeCount: Int
    let unplayedCount: Int
    let latestDate: Date?
}

/// Derived podcast lists. Pure functions so views and tests share exactly the same rules.
enum PodcastLibrary {
    /// Dated episodes first by publication date, then title and identity; undated episodes stay last.
    static func ordered(_ episodes: [TrackRecord], newestFirst: Bool = true) -> [TrackRecord] {
        episodes.sorted { left, right in
            let leftDate = PodcastDate.publication(left), rightDate = PodcastDate.publication(right)
            if (leftDate == nil) != (rightDate == nil) { return leftDate != nil }
            if let leftDate, let rightDate, leftDate != rightDate { return newestFirst ? leftDate > rightDate : leftDate < rightDate }
            let title = left.title.localizedStandardCompare(right.title)
            return title == .orderedSame ? left.id < right.id : title == .orderedAscending
        }
    }

    static func shows(episodes: [TrackRecord], sources: [SourceRecord], state: (TrackRecord) -> PodcastEpisodeState,
                      newestFirst: Bool = true) -> [PodcastShowSummary] {
        let bySource = Dictionary(grouping: episodes, by: \.sourceID)
        let summaries = sources.filter { $0.kind == .podcasts }.map { source -> PodcastShowSummary in
            let values = ordered(bySource[source.id] ?? [])
            return PodcastShowSummary(id: source.id, title: source.name, latestEpisode: values.first, episodeCount: values.count,
                                      unplayedCount: values.reduce(0) { $0 + (state($1).isUnplayed ? 1 : 0) },
                                      latestDate: values.first.flatMap(PodcastDate.publication))
        }
        return summaries.sorted { left, right in
            if (left.latestDate == nil) != (right.latestDate == nil) { return left.latestDate != nil }
            if let leftDate = left.latestDate, let rightDate = right.latestDate, leftDate != rightDate {
                return newestFirst ? leftDate > rightDate : leftDate < rightDate
            }
            let title = left.title.localizedStandardCompare(right.title)
            return title == .orderedSame ? left.id < right.id : title == .orderedAscending
        }
    }

    static func episodes(_ episodes: [TrackRecord], showID: String? = nil, filter: PodcastEpisodeFilter,
                         state: (TrackRecord) -> PodcastEpisodeState, isDownloaded: (TrackRecord) -> Bool,
                         newestFirst: Bool = true) -> [TrackRecord] {
        ordered(episodes.filter { episode in
            guard showID == nil || episode.sourceID == showID else { return false }
            switch filter {
            case .all: return true
            case .unplayed: return state(episode).isUnplayed
            case .downloaded: return isDownloaded(episode)
            }
        }, newestFirst: newestFirst)
    }

    /// Recent unplayed episodes from every show; undated episodes cannot be recent.
    static func newEpisodes(_ episodes: [TrackRecord], state: (TrackRecord) -> PodcastEpisodeState, now: Date = Date(),
                            maxAge: TimeInterval = 30 * 86_400, limit: Int = 200, newestFirst: Bool = true) -> [TrackRecord] {
        let recent = ordered(episodes.filter { episode in
            guard let date = PodcastDate.publication(episode), now.timeIntervalSince(date) <= maxAge else { return false }
            return state(episode).isUnplayed
        })
        let limited = Array(recent.prefix(limit))
        return newestFirst ? limited : ordered(limited, newestFirst: false)
    }

    static func inProgress(_ episodes: [TrackRecord], state: (TrackRecord) -> PodcastEpisodeState,
                           updatedAt: (TrackRecord) -> Date?, limit: Int = .max) -> [TrackRecord] {
        Array(episodes.filter { state($0).isInProgress }.sorted { left, right in
            let leftDate = updatedAt(left) ?? .distantPast, rightDate = updatedAt(right) ?? .distantPast
            return leftDate == rightDate ? left.id < right.id : leftDate > rightDate
        }.prefix(limit))
    }

    static func latestUnplayedPerShow(_ episodes: [TrackRecord], state: (TrackRecord) -> PodcastEpisodeState,
                                      limit: Int = .max) -> [TrackRecord] {
        var seen: Set<String> = []
        return Array(ordered(episodes.filter { state($0).isUnplayed }).filter { seen.insert($0.sourceID).inserted }.prefix(limit))
    }
}
