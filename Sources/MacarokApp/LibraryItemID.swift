import AppKit
import Foundation
import MacarokCore
import UniformTypeIdentifiers

/// A library row that can be selected, activated, or dragged into the active playlist.
enum LibraryItemID: Hashable, Codable, Sendable {
    /// Normalized artist name, shared by every source in the scope.
    case artist(String)
    /// Source-qualified album presentation ID.
    case album(String)
    case track(String)
    case folder(String)
}

extension UTType {
    /// Private to this process: other applications neither offer nor receive library selections.
    static let macarokLibraryItems = UTType(exportedAs: "com.armateurlabs.macarok.library-items")
}

extension LibraryItemID {
    static func itemProvider(_ items: [LibraryItemID]) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(items)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.macarokLibraryItems.identifier, visibility: .ownProcess) { completion in
            completion(data, data == nil ? CocoaError(.coderInvalidValue) : nil)
            return nil
        }
        return provider
    }

    /// Decodes dropped providers in their original order; invalid or foreign payloads are skipped.
    static func load(from providers: [NSItemProvider]) async -> [LibraryItemID] {
        var items: [LibraryItemID] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.macarokLibraryItems.identifier) {
            let data: Data? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.macarokLibraryItems.identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            if let data, let decoded = try? JSONDecoder().decode([LibraryItemID].self, from: data) { items += decoded }
        }
        return items
    }
}
