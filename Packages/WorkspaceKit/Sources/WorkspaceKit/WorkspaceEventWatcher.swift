import CoreServices
import Foundation

public final class WorkspaceEventWatcher {
    private let rootURL: URL
    private let debounceNanoseconds: UInt64
    private let eventHandler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "Plainsong.workspace-events")
    private let queueMarker = DispatchSpecificKey<Void>()

    private var stream: FSEventStreamRef?

    // Confined to `queue`; reach it through `runOnQueue`.
    private var debounceTask: Task<Void, Never>?
    private var stopped = true
    private var generation = 0

    /// `true` before `start()` and after `stop()` returns. Once `stop()` returns, no
    /// `eventHandler` invocation can begin: `stop()` is a hard boundary, not a hint.
    public var isStopped: Bool {
        runOnQueue { stopped }
    }

    public init(
        rootURL: URL,
        debounceNanoseconds: UInt64 = 300_000_000,
        eventHandler: @escaping @Sendable () -> Void
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.debounceNanoseconds = debounceNanoseconds
        self.eventHandler = eventHandler
        queue.setSpecific(key: queueMarker, value: ())
    }

    deinit {
        stop()
    }

    /// Runs `work` serialized on `queue`. Safe to call from `queue` itself, so the
    /// debounce task and `deinit` cannot deadlock against an in-flight callback.
    private func runOnQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueMarker) != nil {
            return work()
        }
        return queue.sync(execute: work)
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
        // Accept events before the stream starts delivering so the earliest batch
        // after a `stop()`/`start()` cycle is not dropped.
        runOnQueue { stopped = false }
        FSEventStreamStart(stream)
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        // The sync block is also a barrier: a callback already dequeued schedules its
        // debounce first and is then cancelled/generation-invalidated here; a
        // callback queued behind it sees `stopped`. Either way nothing that begins
        // after `stop()` returns can reach `eventHandler`.
        runOnQueue {
            stopped = true
            generation += 1
            debounceTask?.cancel()
            debounceTask = nil
        }
    }

    /// Runs on `queue` (the FSEvents dispatch queue).
    private func handleDeliveredEvent() {
        guard !stopped else { return }
        scheduleDebouncedHandler()
    }

    /// Runs on `queue`. The debounce re-validates `generation`/`stopped` under `queue`
    /// before invoking the handler, so a `stop()` interleaving between the event and
    /// the fire always wins.
    private func scheduleDebouncedHandler() {
        debounceTask?.cancel()
        let delay = debounceNanoseconds
        let generation = generation
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            runOnQueue {
                guard !self.stopped, self.generation == generation else { return }
                self.debounceTask = nil
                self.eventHandler()
            }
        }
    }

    /// `@testable` seam: behaves like a delivered FSEvents batch — debounce, then the
    /// handler — without depending on real filesystem event timing.
    func simulateDeliveredEventForTesting() {
        queue.async { [weak self] in
            self?.handleDeliveredEvent()
        }
    }

    private static let eventCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<WorkspaceEventWatcher>.fromOpaque(info).takeUnretainedValue()
        // Already running on `queue`.
        watcher.handleDeliveredEvent()
    }
}
