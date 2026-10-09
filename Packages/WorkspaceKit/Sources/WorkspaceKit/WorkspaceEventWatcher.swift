import CoreServices
import Foundation

public final class WorkspaceEventWatcher {
    private let rootURL: URL
    private let debounceNanoseconds: UInt64
    private let eventHandler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "Plainsong.workspace-events")

    private var stream: FSEventStreamRef?
    private var debounceTask: Task<Void, Never>?

    #if DEBUG
        /// Handoff 27b diagnostics: raw FSEvents paths as delivered (pre-debounce).
        public var onEventForTesting: (@Sendable ([String]) -> Void)?
        /// Whether the FSEventStream is currently started.
        public var isStreamingForTesting: Bool {
            stream != nil
        }
    #endif

    public init(
        rootURL: URL,
        debounceNanoseconds: UInt64 = 300_000_000,
        eventHandler: @escaping @Sendable () -> Void
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.debounceNanoseconds = debounceNanoseconds
        self.eventHandler = eventHandler
    }

    deinit {
        stop()
    }

    public func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer |
                kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            nil,
            WorkspaceEventWatcher.eventCallback,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Double(debounceNanoseconds) / 1_000_000_000,
            flags
        ) else {
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        debounceTask?.cancel()
        debounceTask = nil

        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scheduleDebouncedHandler() {
        debounceTask?.cancel()
        let delay = debounceNanoseconds
        let eventHandler = eventHandler
        debounceTask = Task {
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            eventHandler()
        }
    }

    private static let eventCallback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<WorkspaceEventWatcher>.fromOpaque(info).takeUnretainedValue()
        #if DEBUG
            if let onEvent = watcher.onEventForTesting {
                let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                onEvent((cfArray as? [String]) ?? [])
            }
        #endif
        watcher.scheduleDebouncedHandler()
    }
}
