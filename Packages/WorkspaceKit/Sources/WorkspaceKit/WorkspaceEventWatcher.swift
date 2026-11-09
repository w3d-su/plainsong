import CoreServices
import Foundation

/// Concurrency rule behind `@unchecked Sendable`:
/// - `stream` is owned by the caller's thread (the main thread in the app): only `start()`,
///   `stop()` and `deinit` touch it, and callers must not race them against each other.
/// - `debounceTask`, `debounceToken`, `pendingSince`, `eventPathFilter`, `stopped` and
///   `generation` are confined to `queue` through `runOnQueue`; the FSEvents callback,
///   debounce tasks, `isStopped`, `setEventPathFilter`, `stop()` and `deinit` reach them
///   only there.
/// - `eventHandler` runs inside `queue`'s critical section (a `runOnQueue` block), so it
///   must never block on the main thread: `stop()`/`isStopped` on main wait on `queue`, and
///   a handler that synchronously waited for main would deadlock. Hop asynchronously.
///
/// Each delivered batch restarts the debounce, but never past `maximumDelayNanoseconds`
/// after the first batch the handler has not seen yet: a tool that keeps writing (a dev
/// server, a long `git` operation) no longer postpones the handler indefinitely. A batch
/// whose every path `eventPathFilter` rejects does not count at all.
public final class WorkspaceEventWatcher: @unchecked Sendable {
    private let rootURL: URL
    private let debounceNanoseconds: UInt64
    private let maximumDelayNanoseconds: UInt64
    private let eventHandler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "Plainsong.workspace-events")
    private let queueMarker = DispatchSpecificKey<Void>()

    /// Owned by the caller's thread; see the type comment.
    private var stream: FSEventStreamRef?

    // Confined to `queue`; reach it through `runOnQueue`.
    private var debounceTask: Task<Void, Never>?
    private var debounceToken: UInt64 = 0
    /// Uptime of the first delivered batch the handler has not run for yet.
    private var pendingSince: UInt64?
    private var eventPathFilter: WorkspaceEventPathFilter?
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
        maximumDelayNanoseconds: UInt64 = 2_000_000_000,
        eventHandler: @escaping @Sendable () -> Void
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.debounceNanoseconds = debounceNanoseconds
        self.maximumDelayNanoseconds = max(maximumDelayNanoseconds, debounceNanoseconds)
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

    /// Replaces the filter batches are matched against; `nil` makes every batch count.
    /// Takes effect for batches delivered after it returns.
    public func setEventPathFilter(_ filter: WorkspaceEventPathFilter?) {
        runOnQueue { eventPathFilter = filter }
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
            pendingSince = nil
        }
    }

    /// Runs on `queue` (the FSEvents dispatch queue).
    private func handleDeliveredEvents(_ events: [WorkspaceEventPathFilter.Event]) {
        guard !stopped else { return }
        if let eventPathFilter, !eventPathFilter.isRelevant(events) { return }
        scheduleDebouncedHandler()
    }

    /// Runs on `queue`. The debounce re-validates `generation`/`stopped` and its own token
    /// under `queue` before invoking the handler, so a `stop()` or a newer batch
    /// interleaving between the event and the fire always wins.
    private func scheduleDebouncedHandler() {
        debounceTask?.cancel()
        let now = DispatchTime.now().uptimeNanoseconds
        let firstPending = pendingSince ?? now
        pendingSince = firstPending
        let deadline = firstPending &+ maximumDelayNanoseconds
        let delay = min(debounceNanoseconds, deadline > now ? deadline - now : 0)
        let generation = generation
        debounceToken &+= 1
        let token = debounceToken
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            runOnQueue {
                guard !self.stopped,
                      self.generation == generation,
                      self.debounceToken == token
                else { return }
                self.debounceTask = nil
                self.pendingSince = nil
                self.eventHandler()
            }
        }
    }

    /// `@testable` seam: behaves like a delivered FSEvents batch — debounce, then the
    /// handler — without depending on real filesystem event timing.
    func simulateDeliveredEventForTesting() {
        simulateDeliveredEventsForTesting([])
    }

    /// `@testable` seam for a batch with specific paths and flags.
    func simulateDeliveredEventsForTesting(_ events: [WorkspaceEventPathFilter.Event]) {
        queue.async { [weak self] in
            self?.handleDeliveredEvents(events)
        }
    }

    private static let eventCallback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
        guard let info else { return }
        let watcher = Unmanaged<WorkspaceEventWatcher>.fromOpaque(info).takeUnretainedValue()
        // `kFSEventStreamCreateFlagUseCFTypes`: the paths are a CFArray of CFString.
        let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
        var events: [WorkspaceEventPathFilter.Event] = []
        events.reserveCapacity(eventCount)
        for index in 0 ..< eventCount {
            events.append(.init(
                path: index < paths.count ? paths[index] : nil,
                flags: eventFlags[index]
            ))
        }
        // Already running on `queue`.
        watcher.handleDeliveredEvents(events)
    }
}

/// Which delivered paths can change what the workspace shows.
///
/// With "Show all files" off the scan skips ignored directories (`node_modules`, `.git`,
/// `dist`, …) except the chain down to an open document. A batch whose every path lies in
/// such a skipped subtree changes neither the tree nor an open document, so it is not
/// delivered: a dev server rewriting `node_modules/.vite` no longer triggers a full rescan.
/// Any path outside the root, an event without a path, and every rescan, drop, mount or
/// root-change flag always count.
public struct WorkspaceEventPathFilter: Sendable {
    public struct Event: Sendable, Equatable {
        public let path: String?
        public let flags: FSEventStreamEventFlags

        public init(path: String?, flags: FSEventStreamEventFlags = 0) {
            self.path = path
            self.flags = flags
        }
    }

    private static let alwaysRelevantFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs |
            kFSEventStreamEventFlagUserDropped |
            kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagRootChanged |
            kFSEventStreamEventFlagMount |
            kFSEventStreamEventFlagUnmount
    )

    /// The root's path spellings, each ending in `/` (FSEvents reports resolved paths).
    private let rootPrefixes: [String]
    private let pruning: WorkspaceScanPruning

    public init(rootURL: URL, pruning: WorkspaceScanPruning) {
        let spellings = [rootURL.standardizedFileURL, rootURL.resolvingSymlinksInPath()]
            .map { $0.path(percentEncoded: false) }
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        rootPrefixes = Array(Set(spellings))
        self.pruning = pruning
    }

    func isRelevant(_ events: [Event]) -> Bool {
        guard case .ignoredDirectories = pruning, !events.isEmpty else { return true }
        return events.contains { event in
            guard event.flags & Self.alwaysRelevantFlags == 0, let path = event.path else { return true }
            return isRelevant(path: path)
        }
    }

    func isRelevant(path: String) -> Bool {
        guard case let .ignoredDirectories(retained) = pruning,
              let prefix = rootPrefixes.first(where: { path.hasPrefix($0) })
        else {
            return true
        }
        let relativePath = String(path.dropFirst(prefix.count))
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.contains(where: { WorkspaceIgnoredDirectories.contains(String($0)) }) else {
            return true
        }
        // Inside an ignored directory only the retained chain is scanned.
        let normalized = components.joined(separator: "/")
        let descendantPrefix = normalized + "/"
        return retained.contains { $0 == normalized || $0.hasPrefix(descendantPrefix) }
    }
}
