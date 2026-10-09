@testable import WorkspaceKit
import XCTest

/// `WorkspaceEventWatcher.stop()` is a hard boundary: no handler invocation may begin
/// after it returns, whether the debounce was scheduled before or after the call. These
/// tests drive the watcher's delivered-event seam so no FSEvents timing is involved.
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
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
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
}
