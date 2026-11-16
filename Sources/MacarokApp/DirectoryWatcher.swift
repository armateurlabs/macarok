import CoreServices
import Foundation

/// Watches a selected source recursively. A weak context keeps delayed FSEvents safe after teardown.
final class DirectoryWatcher: @unchecked Sendable {
    private final class CallbackBox {
        weak var owner: DirectoryWatcher?
        init(_ owner: DirectoryWatcher) { self.owner = owner }
    }
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable (DirectoryChangeBatch) -> Void

    init(url: URL, onChange: @escaping @Sendable (DirectoryChangeBatch) -> Void) {
        self.onChange = onChange
        let box = CallbackBox(self)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: { pointer in
            guard let pointer else { return nil }
            return UnsafeRawPointer(Unmanaged<CallbackBox>.fromOpaque(pointer).retain().toOpaque())
        }, release: { pointer in
            if let pointer { Unmanaged<CallbackBox>.fromOpaque(pointer).release() }
        }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        stream = FSEventStreamCreate(nil, { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
            let batch = DirectoryWatcher.changeBatch(paths: paths, flags: flags)
            Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().owner?.onChange(batch)
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.5, flags)
        if let stream { FSEventStreamSetDispatchQueue(stream, .global(qos: .utility)); FSEventStreamStart(stream) }
    }

    static func changeBatch(paths: [String], flags: [FSEventStreamEventFlags]) -> DirectoryChangeBatch {
        let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
            kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged |
            kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        let directories = Set(zip(paths, flags).filter { $0.1 & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 }.map(\.0))
        let files = Set(zip(paths, flags).filter { $0.1 & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 }.map(\.0))
        return DirectoryChangeBatch(paths: paths,
            mustRescan: paths.isEmpty || paths.count != flags.count || flags.contains { $0 & rescanFlags != 0 },
            directoryPaths: directories, filePaths: files)
    }

    func stop() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
    }
    deinit { stop() }
}
