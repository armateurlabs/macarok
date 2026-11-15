import Foundation
import GRDB

extension LibraryStore {
    public func albumTracks(sourceID: String, albumID: String) throws -> [TrackRecord] {
        try database.read { db in
            try TrackRecord.fetchAll(db, sql: "SELECT * FROM tracks WHERE sourceID = ? AND albumID = ? AND isAvailable = 1", arguments: [sourceID, albumID])
        }
    }
}
