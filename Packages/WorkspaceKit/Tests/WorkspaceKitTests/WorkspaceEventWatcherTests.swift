import CoreServices
@testable import WorkspaceKit
import XCTest

/// `WorkspaceEventWatcher.stop()` is a hard boundary: no handler invocation may begin
/// after it returns, whether the debounce was scheduled before or after the call. These
/// tests drive the watcher's delivered-event seam so no FSEvents timing is involved.
///
/// The watched path is deliberately never created: a live FSEventStream can still
/// deliver real events for its root — fseventsd batches deliveries and a delayed or
/// resync event can reach the handler inside the debounce/assert window, making an
/// exact handler count nondeterministic (observed as calls==2 in
/// testStopThenStartDeliversASimulatedEventOnce). A path nothing writes leaves the
/// simulated seam as the only event source.
final class WorkspaceEventWatcherTests: XCTestCase {
    private final class HandlerCallCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private func makeWatcher(
        debounceNanoseconds: UInt64 = 20_000_000,
        handler: @escaping @Sendable () -> Void
    ) throws -> WorkspaceEventWatcher {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceEventWatcherTests-\(UUID().uuidString)")
        return WorkspaceEventWatcher(
            rootURL: root,
            debounceNanoseconds: debounceNanoseconds,
            eventHandler: handler
        )
    }

    func testStopBeforeDebounceElapsesSuppressesTheHandler() async throws {
        let calls = HandlerCallCount()
        let watcher = try makeWatcher { calls.increment() }
        watcher.start()

        watcher.simulateDeliveredEventForTesting()
        watcher.stop()

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(calls.value, 0)
    }

    func testEventDeliveredAfterStopNeverReachesTheHandler() async throws {
        let calls = HandlerCallCount()
        let watcher = try makeWatcher { calls.increment() }
        watcher.start()
        watcher.stop()

        watcher.simulateDeliveredEventForTesting()

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(calls.value, 0)
    }

    func testStopThenStartDeliversASimulatedEventOnce() async throws {
        let calls = HandlerCallCount()
        let watcher = try makeWatcher { calls.increment() }
        watcher.start()
        watcher.stop()
        watcher.start()

        watcher.simulateDeliveredEventForTesting()

        let deadline = Date().addingTimeInterval(2)
        while calls.value == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(calls.value, 1)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(calls.value, 1)
    }

    func testIsStoppedTracksStartAndStop() throws {
        let watcher = try makeWatcher {}
        XCTAssertTrue(watcher.isStopped)
        watcher.start()
        XCTAssertFalse(watcher.isStopped)
        watcher.stop()
        XCTAssertTrue(watcher.isStopped)
    }

    func testContinuousBatchesStillReachTheHandlerByTheMaximumDelay() async throws {
        let calls = HandlerCallCount()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceEventWatcherTests-\(UUID().uuidString)")
        let watcher = WorkspaceEventWatcher(
            rootURL: root,
            debounceNanoseconds: 60_000_000,
            maximumDelayNanoseconds: 200_000_000
        ) { calls.increment() }
        watcher.start()
        defer { watcher.stop() }

        // A batch every 20 ms keeps restarting the 60 ms debounce; without a maximum
        // delay the handler would never run while the writer keeps going.
        let start = Date()
        while calls.value == 0, Date().timeIntervalSince(start) < 2 {
            watcher.simulateDeliveredEventForTesting()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(calls.value, 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testBatchesInsideIgnoredDirectoriesDoNotReachTheHandler() async throws {
        let calls = HandlerCallCount()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceEventWatcherTests-\(UUID().uuidString)")
        let watcher = WorkspaceEventWatcher(rootURL: root, debounceNanoseconds: 20_000_000) { calls.increment() }
        watcher.setEventPathFilter(WorkspaceEventPathFilter(
            rootURL: root,
            pruning: .ignoredDirectories(retaining: [])
        ))
        watcher.start()
        defer { watcher.stop() }
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)

        watcher.simulateDeliveredEventsForTesting([
            .init(path: rootPath + "/node_modules/.vite/deps/chunk.js"),
            .init(path: rootPath + "/.git/index.lock"),
        ])
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(calls.value, 0)

        watcher.simulateDeliveredEventsForTesting([
            .init(path: rootPath + "/node_modules/.vite/deps/chunk.js"),
            .init(path: rootPath + "/posts/hello.md"),
        ])
        let deadline = Date().addingTimeInterval(2)
        while calls.value == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(calls.value, 1)
    }

    func testEventPathFilterKeepsRetainedChainsFlagsAndShowAllFiles() {
        let root = URL(fileURLWithPath: "/tmp/plainsong-filter-root", isDirectory: true)
        let filter = WorkspaceEventPathFilter(
            rootURL: root,
            pruning: .ignoredDirectories(retaining: ["node_modules/pkg/README.md"])
        )
        let base = root.standardizedFileURL.path(percentEncoded: false)

        XCTAssertTrue(filter.isRelevant(path: base + "/posts/a.md"))
        XCTAssertTrue(filter.isRelevant(path: base + "/node_modules/pkg/README.md"))
        XCTAssertTrue(filter.isRelevant(path: base + "/node_modules/pkg"))
        XCTAssertTrue(filter.isRelevant(path: base + "/node_modules"))
        XCTAssertFalse(filter.isRelevant(path: base + "/node_modules/pkg/index.js"))
        XCTAssertFalse(filter.isRelevant(path: base + "/node_modules/other/README.md"))
        XCTAssertFalse(filter.isRelevant(path: base + "/Dist/index.html"), "names compare case-insensitively")
        XCTAssertTrue(filter.isRelevant(path: "/elsewhere/node_modules/x.js"), "outside the root counts")
        XCTAssertTrue(filter.isRelevant(path: base), "the root itself counts")

        let ignoredOnly = [WorkspaceEventPathFilter.Event(path: base + "/.git/HEAD")]
        XCTAssertFalse(filter.isRelevant(ignoredOnly))
        XCTAssertTrue(filter.isRelevant([.init(
            path: base + "/.git/HEAD",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        )]))
        XCTAssertTrue(filter.isRelevant([.init(path: nil)]))
        XCTAssertTrue(filter.isRelevant([]))

        let showAll = WorkspaceEventPathFilter(rootURL: root, pruning: .none)
        XCTAssertTrue(showAll.isRelevant(ignoredOnly))
    }
}
