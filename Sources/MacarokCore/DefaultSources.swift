import Foundation
import GRDB

/// Sources that every library starts with, so their directories are reachable without setup.
public enum DefaultSource: String, Codable, CaseIterable, Sendable {
    case radio, podcasts, liveMusicArchive, librivox

    static let dismissedKey = "Macarok.dismissedDefaultSources"

    public var record: SourceRecord {
        switch self {
        case .radio: SourceRecord(id: RadioLibrary.sourceID, kind: .radio, name: "Internet Radio", location: "", createdAt: Date(timeIntervalSince1970: 0))
        case .podcasts: PodcastDirectorySource.record
        case .liveMusicArchive: Self.archive(.liveMusic)
        case .librivox: Self.archive(.librivox)
        }
    }

    /// The default a source stands for, if any; an archive collection counts whatever its record ID.
    public init?(_ source: SourceRecord) {
        switch source.kind {
        case .radio where source.id == RadioLibrary.sourceID: self = .radio
        case .podcastDirectory: self = .podcasts
        case .internetArchive:
            switch ArchiveCollection(location: source.location) {
            case .liveMusic: self = .liveMusicArchive
            case .librivox: self = .librivox
            case nil: return nil
            }
        default: return nil
        }
    }

    private static func archive(_ collection: ArchiveCollection) -> SourceRecord {
        SourceRecord(id: StableID.make("default-source", collection.rawValue), kind: .internetArchive, name: collection.title,
                     location: collection.location, createdAt: Date(timeIntervalSince1970: 0))
    }
}

extension LibraryStore {
    /// Adds the defaults the library lacks, except those the user removed, and returns every source.
    @discardableResult
    public func ensureDefaultSources() throws -> [SourceRecord] {
        let dismissed = try dismissedDefaultSources()
        return try database.write { db in
            let existing = Set(try SourceRecord.fetchAll(db).compactMap(DefaultSource.init))
            for value in DefaultSource.allCases where !existing.contains(value) && !dismissed.contains(value) {
                try value.record.insert(db)
            }
            return try SourceRecord.fetchAll(db, sql: "SELECT * FROM sources ORDER BY createdAt, name COLLATE NOCASE")
        }
    }

    public func dismissedDefaultSources() throws -> Set<DefaultSource> {
        guard let data = try value(forKey: DefaultSource.dismissedKey) else { return [] }
        return (try? JSONDecoder().decode(Set<DefaultSource>.self, from: data)) ?? []
    }

    /// Removing a default keeps it out of later launches; adding it back clears that choice.
    public func setDefaultSource(_ value: DefaultSource, dismissed: Bool) throws {
        var values = try dismissedDefaultSources()
        if dismissed { values.insert(value) } else { values.remove(value) }
        try setValue(try JSONEncoder().encode(values), forKey: DefaultSource.dismissedKey)
    }
}
