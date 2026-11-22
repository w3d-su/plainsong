import CoreServices
import Foundation

/// Keeps a fixture's own file writes from reaching a workspace watcher started afterwards.
///
/// A hosted fixture writes its files and opens them as a workspace a few milliseconds
/// later. `WorkspaceEventWatcher` asks FSEvents for events "since now", but FSEvents
/// numbers an event when its daemon reads it from the kernel, which can be after the
/// write returned. A watcher started right after the writes therefore sometimes receives
/// them (18 of 130 fixtures in a local probe) and refreshes the workspace roughly 300 ms
/// into the test: a disk inspection that makes Replace refuse with
/// `externalObservationPending`, an authority-generation advance that supersedes a
/// Replace All plan, and a reload whose lagging capture refuses a Files pick. Each hosted
/// test hit by that was patched on its own (#142, #151, #201); this closes the window
/// for every fixture.
///
/// FSEvents delivers events in the order the kernel recorded them. `settle` makes and
/// removes a sentinel directory after the fixture's writes and waits for the sentinel's
/// removal to be delivered. By then every earlier event has its number, so a stream
/// created later, whose "now" is a later number, cannot receive it.
enum WorkspaceFixtureEventSettle {
    private final class Sentinel: @unchecked Sendable {
        let pathSuffix: String
        let removalDelivered = DispatchSemaphore(value: 0)

        init(name: String) {
            pathSuffix = "/" + name
        }
    }

    /// Blocks until FSEvents has delivered everything already written under `root`.
    ///
    /// Returns `false` when the sentinel could not be made or its removal was not
    /// delivered within `timeout`. The fixture is then as it was before this helper
    /// existed: usable, with a creation event that may still arrive late.
    @discardableResult
    static func settle(root: URL, timeout: TimeInterval = 5) -> Bool {
        let name = ".plainsong-fixture-settle-\(UUID().uuidString)"
        let sentinel = Sentinel(name: name)
        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(sentinel).toOpaque()),
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
            eventCallback,
            &context,
            [root.standardizedFileURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            flags
        ) else {
            return false
        }
        let queue = DispatchQueue(label: "Plainsong.tests.fixture-event-settle")
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        defer {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            // A callback already running still reads `sentinel`: let it finish, and keep
            // the object alive until it has.
            queue.sync {}
            withExtendedLifetime(sentinel) {}
        }

        let sentinelURL = root.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: sentinelURL, withIntermediateDirectories: false)
            try FileManager.default.removeItem(at: sentinelURL)
        } catch {
            try? FileManager.default.removeItem(at: sentinelURL)
            return false
        }
        return sentinel.removalDelivered.wait(timeout: .now() + timeout) == .success
    }

    private static let eventCallback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
        guard let info else { return }
        let sentinel = Unmanaged<Sentinel>.fromOpaque(info).takeUnretainedValue()
        // `kFSEventStreamCreateFlagUseCFTypes`: the paths are a CFArray of CFString.
        let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
        let removed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
        for index in 0 ..< min(eventCount, paths.count)
            where paths[index].hasSuffix(sentinel.pathSuffix) && eventFlags[index] & removed != 0
        {
            sentinel.removalDelivered.signal()
        }
    }
}
