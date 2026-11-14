import CoreServices
import Foundation

/// Watches a selected source recursively. A weak context keeps delayed FSEvents safe after teardown.
final class DirectoryWatcher: @unchecked Sendable {
    private final class CallbackBox {
        weak var owner: DirectoryWatcher?
        init(_ owner: DirectoryWatcher) { self.owner = owner }
    }
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        let box = CallbackBox(self)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: { pointer in
            guard let pointer else { return nil }
            return UnsafeRawPointer(Unmanaged<CallbackBox>.fromOpaque(pointer).retain().toOpaque())
        }, release: { pointer in
            if let pointer { Unmanaged<CallbackBox>.fromOpaque(pointer).release() }
        }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().owner?.onChange()
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.5, flags)
        if let stream { FSEventStreamSetDispatchQueue(stream, .global(qos: .utility)); FSEventStreamStart(stream) }
    }

    func stop() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
    }
    deinit { stop() }
}
