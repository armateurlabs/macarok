import Foundation
import GRDB

public enum RadioStoreStorage {
    public static func registerMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("radio-stations-v1") { db in
            try db.execute(sql: """
                CREATE TABLE radioStations (
                    trackID TEXT PRIMARY KEY NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
                    directoryID TEXT,
                    isFavorite BOOLEAN NOT NULL DEFAULT 0,
                    payload BLOB NOT NULL
                );
                CREATE INDEX radioStations_favorites ON radioStations(isFavorite);
                """)
        }
    }
}

extension LibraryStore {
    public func saveRadioStation(_ value: RadioStationRecord, favorite: Bool? = nil) throws {
        _ = try RadioError.validatedURL(value.streamURL)
        if let resolved = value.resolvedURL { _ = try RadioError.validatedURL(resolved) }
        var station = value
        try database.write { db in
            try Task.checkCancellation()
            if let source = try SourceRecord.fetchOne(db, key: station.sourceID) {
                guard source.kind == .radio else { throw RadioError.invalidResponse }
            } else {
                try SourceRecord(id: station.sourceID, kind: .radio, name: "Internet Radio", location: "").insert(db)
            }
            let existing = try Row.fetchOne(db, sql: "SELECT isFavorite FROM radioStations WHERE trackID = ?", arguments: [station.id])
            station.isFavorite = favorite ?? existing.map { $0["isFavorite"] as Bool } ?? station.isFavorite
            try station.track.save(db)
            try db.execute(sql: """
                INSERT INTO radioStations(trackID,directoryID,isFavorite,payload) VALUES (?,?,?,?)
                ON CONFLICT(trackID) DO UPDATE SET directoryID=excluded.directoryID,isFavorite=excluded.isFavorite,payload=excluded.payload
                """, arguments: [station.id, station.directoryID, station.isFavorite, try JSONEncoder().encode(station)])
        }
    }

    public func radioStation(id: String) throws -> RadioStationRecord? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT payload FROM radioStations WHERE trackID = ?", arguments: [id]) else { return nil }
            return try JSONDecoder().decode(RadioStationRecord.self, from: row["payload"] as Data)
        }
    }

    public func radioStations(scope: LibraryScope = .all, query: String = "") throws -> [RadioStationRecord] {
        if scope == .podcasts { return [] }
        return try database.read { db in
            var sql = "SELECT radioStations.payload FROM radioStations JOIN tracks ON tracks.id=radioStations.trackID WHERE tracks.isAvailable=1"
            var arguments = StatementArguments()
            if let sourceID = scope.sourceID { sql += " AND tracks.sourceID=?"; arguments += [sourceID] }
            return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
                let station = try JSONDecoder().decode(RadioStationRecord.self, from: row["payload"] as Data)
                let text = [station.name,station.country,station.language,station.tags].joined(separator: " ")
                return query.isEmpty || text.localizedStandardContains(query) ? station : nil
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}
