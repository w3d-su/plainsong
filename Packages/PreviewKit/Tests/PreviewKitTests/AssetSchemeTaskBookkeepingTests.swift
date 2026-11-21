import Foundation
@testable import PreviewKit
import XCTest

/// The handler's per-task bookkeeping ends with the read, so a long preview session
/// does not keep a task handle per image or an identifier per stopped request.
@MainActor
final class AssetSchemeTaskBookkeepingTests: XCTestCase {
    private var root: URL!
    private var handler: AssetURLSchemeHandler!
    private var reader: GatePreviewAssetReader!
    private var token = ""

    override func setUp() async throws {
        root = try PreviewAssetTestSupport.directory()
        handler = AssetURLSchemeHandler()
        reader = GatePreviewAssetReader()
        handler.installReader(reader)
        token = handler.updateAuthority(PreviewAssetTestSupport.access(root: root, generation: 1)).token
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDeliveredReadLeavesNothingTracked() async {
        let task = await startRead()
        let finished = expectation(description: "delivered")
        task.onTerminal = { finished.fulfill() }
        reader.resumeFirst(bytes: PreviewAssetTestSupport.onePixelPNG)
        await fulfillment(of: [finished], timeout: 2)

        await waitUntilNothingIsTracked()
        XCTAssertEqual(task.finished, 1)
    }

    func testStoppedReadLeavesNothingTrackedOnceItReturns() async {
        let task = await startRead()
        handler.stop(task)
        XCTAssertGreaterThan(handler.trackedTaskCount, 0, "the stop is fenced while the read runs")
        reader.resumeFirst(bytes: PreviewAssetTestSupport.onePixelPNG)

        await waitUntilNothingIsTracked()
        XCTAssertEqual(task.finished + task.failures + task.responseCount, 0)
    }

    func testStoppedReadThatFailsLateNeverCallsTheStoppedTask() async {
        let task = await startRead()
        handler.stop(task)
        reader.failFirst(CocoaError(.fileReadNoPermission))

        await waitUntilNothingIsTracked()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertEqual(task.finished + task.failures + task.responseCount, 0)
    }

    func testStopForATaskWithNoReadIsNotRecorded() {
        handler.stop(RecordingSchemeTask(url: PreviewAssetTestSupport.assetURL(token: token)))
        let stale = RecordingSchemeTask(url: PreviewAssetTestSupport.assetURL(token: "stale"))
        handler.start(stale)
        handler.stop(stale)

        XCTAssertEqual(stale.failures, 1)
        XCTAssertEqual(handler.trackedTaskCount, 0)
    }

    func testInvalidatedReadLeavesNothingTrackedOnceItReturns() async {
        let task = await startRead()
        handler.invalidateReads()
        handler.stop(task)
        reader.resumeFirst(bytes: PreviewAssetTestSupport.onePixelPNG)

        await waitUntilNothingIsTracked()
        XCTAssertEqual(task.finished + task.failures, 0)
    }

    private func startRead() async -> RecordingSchemeTask {
        let task = RecordingSchemeTask(url: PreviewAssetTestSupport.assetURL(token: token))
        handler.start(task)
        let reader = reader!
        await PreviewAssetTestSupport.waitUntil("read started") { reader.hasWaiter() }
        return task
    }

    private func waitUntilNothingIsTracked() async {
        let handler = handler!
        await PreviewAssetTestSupport.waitUntil("bookkeeping cleared") { handler.trackedTaskCount == 0 }
    }
}
