import Foundation
import MacarokCore

struct ServerScanProgress: Equatable {
    var sourceID: String
    var sourceName: String
    var count: Int?
    var position = 1
    var total = 1

    var title: String {
        let files = count.map { " · \($0.formatted()) files" } ?? ""
        let batch = total > 1 ? " (\(position) of \(total))" : ""
        return "Scanning \(sourceName)\(batch)\(files)"
    }
}

extension AppModel {
    /// OpenSubsonic servers in the current scope; their own scan finds files added on the server.
    var serverScanSources: [SourceRecord] { sources.filter { $0.kind == .openSubsonic && scopeIncludes(sourceID: $0.id) } }

    /// Asks each server to scan its music folders, follows its progress, then refreshes the library
    /// so new albums appear. A server that refuses (non-administrator) leaves the others untouched.
    func scanServerLibrary(_ requested: [SourceRecord]? = nil, fullScan: Bool = false) {
        let targets = (requested ?? serverScanSources).filter { $0.kind == .openSubsonic }
        guard serverScan == nil, !targets.isEmpty else { return }
        serverScanTask = Task { [weak self] in
            guard let self else { return }
            defer { self.serverScan = nil; self.serverScanTask = nil }
            var scanned: [SourceRecord] = [], refused: [String] = [], failures: [String] = []
            for (index, source) in targets.enumerated() {
                guard !Task.isCancelled, self.sourcesByID[source.id] != nil else { continue }
                self.serverScan = ServerScanProgress(sourceID: source.id, sourceName: source.name, position: index + 1, total: targets.count)
                do {
                    let client = try await self.subsonicClient(source)
                    _ = try await OpenSubsonicScanStatus.run(start: { try await client.startScan(fullScan: fullScan) },
                                                             status: { try await client.scanStatus() }) { status in
                        self.serverScan?.count = status.count
                    }
                    scanned.append(source)
                } catch is CancellationError {
                    self.status = "Stopped following the server scan; the server may still be scanning."
                    return
                } catch where OpenSubsonicError.isNotAuthorized(error) {
                    refused.append(source.name)
                } catch {
                    if Task.isCancelled { return }
                    failures.append("“\(source.name)”: \(error.localizedDescription)")
                }
            }
            if !refused.isEmpty {
                self.fail("Server scan not allowed",
                          "Only an administrator account can start a library scan on \(refused.joined(separator: ", ")). Refresh Source still reads what the server already knows.")
            } else if !failures.isEmpty {
                self.fail("Could not scan the server", failures.joined(separator: "\n"))
            }
            guard !scanned.isEmpty else { return }
            self.status = scanned.count == 1 ? "“\(scanned[0].name)” finished scanning. Refreshing…" : "\(scanned.count) servers finished scanning. Refreshing…"
            self.startRefresh(sources: scanned)
        }
    }

    /// Stops following progress; the server itself cannot be asked to stop a scan.
    func stopServerScanMonitoring() { serverScanTask?.cancel() }
}
