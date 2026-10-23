import Foundation
import MarkdownCore
@testable import PlainsongIOS
import XCTest

final class IOSProductionFindSchedulerTests: XCTestCase {
    @MainActor
    func testRunningScanDrainsBeforeOnlyLatestPendingStarts() async {
        let scheduler = IOSAuthoringDetachedFindScheduler()
        let started = expectation(description: "first scan entered")
        let delivered = expectation(description: "latest result delivered")
        let probe = ProductionFindProbe(started: started)
        var results: [String] = []
        scheduler.schedule(operation: { probe.search("first", blocked: true) }, deliver: {
            results.append($0.query.pattern)
        })
        await fulfillment(of: [started], timeout: 5)
        scheduler.schedule(operation: { probe.search("middle") }, deliver: { results.append($0.query.pattern) })
        scheduler.schedule(operation: { probe.search("latest") }, deliver: {
            results.append($0.query.pattern)
            delivered.fulfill()
        })
        probe.release.signal()
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(probe.names, ["first", "latest"])
        XCTAssertEqual(probe.maximumRunning, 1)
        XCTAssertFalse(probe.ranOnMain)
        XCTAssertEqual(results, ["latest"])
    }

    @MainActor
    func testCancelDropsQueuedScanAndRunningResultBeforeReuse() async {
        let scheduler = IOSAuthoringDetachedFindScheduler()
        let started = expectation(description: "running entered")
        let delivered = expectation(description: "replacement delivered")
        let probe = ProductionFindProbe(started: started)
        var results: [String] = []
        scheduler.schedule(operation: { probe.search("first", blocked: true) }, deliver: {
            results.append($0.query.pattern)
        })
        await fulfillment(of: [started], timeout: 5)
        scheduler.schedule(operation: { probe.search("cancelledPending") }, deliver: {
            results.append($0.query.pattern)
        })
        scheduler.cancel()
        scheduler.schedule(operation: { probe.search("afterCancel") }, deliver: {
            results.append($0.query.pattern)
            delivered.fulfill()
        })
        probe.release.signal()
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(probe.names, ["first", "afterCancel"])
        XCTAssertEqual(probe.maximumRunning, 1)
        XCTAssertEqual(results, ["afterCancel"])
    }

    @MainActor
    func testCancelBeforeRunnerStartsDoesNotScanTheCancelledQuery() async {
        let scheduler = IOSAuthoringDetachedFindScheduler()
        let delivered = expectation(description: "current delivered")
        let probe = ProductionFindProbe()
        scheduler.schedule(operation: { probe.search("cancelled") }, deliver: { _ in XCTFail("stale result") })
        scheduler.cancel()
        scheduler.schedule(operation: { probe.search("current") }, deliver: { _ in delivered.fulfill() })
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(probe.names, ["current"])
    }
}

private final class ProductionFindProbe: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let started: XCTestExpectation?
    private var running = 0
    private var recordedMaximum = 0
    private var recordedNames: [String] = []
    private var recordedMain = false

    init(started: XCTestExpectation? = nil) {
        self.started = started
    }

    var names: [String] {
        read { recordedNames }
    }

    var maximumRunning: Int {
        read { recordedMaximum }
    }

    var ranOnMain: Bool {
        read { recordedMain }
    }

    func search(_ name: String, blocked: Bool = false) -> EditorFindSession {
        lock.lock()
        running += 1
        recordedMaximum = max(recordedMaximum, running)
        recordedNames.append(name)
        recordedMain = recordedMain || Thread.isMainThread
        lock.unlock()
        if blocked {
            started?.fulfill()
            release.wait()
        }
        let session = EditorFindSession.search(in: name, query: TextSearchQuery(pattern: name))
        lock.lock()
        running -= 1
        lock.unlock()
        return session
    }

    private func read<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
