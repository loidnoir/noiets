import Foundation
import CoreServices

/// Recursive vault watcher built on FSEvents (one stream for the whole tree —
/// scales where per-file dispatch sources don't). Persists the last event id
/// per vault so a relaunch replays what happened while the app was closed.
public final class FSEventsWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let root: URL
    private let onEvents: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "com.noiets.fsevents")
    private let defaultsKey: String

    public init(root: URL, onEvents: @escaping @Sendable ([String]) -> Void) {
        self.root = root
        self.onEvents = onEvents
        self.defaultsKey = "fsevents-last-id-\(root.path.hashValue)"
    }

    public func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let sinceWhen = UserDefaults.standard.object(forKey: defaultsKey) as? UInt64
            ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)

        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.handle(paths: Array(cfPaths.prefix(count)))
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            sinceWhen,
            0.3, // latency: coalesce bursts
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagWatchRoot
            )
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func handle(paths: [String]) {
        if let stream {
            let lastId = FSEventStreamGetLatestEventId(stream)
            UserDefaults.standard.set(lastId, forKey: defaultsKey)
        }
        onEvents(paths)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
