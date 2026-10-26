import Foundation
import MarkdownCore
@testable import PreviewKit
import XCTest

@MainActor
final class PreviewInitialReadinessTests: XCTestCase {
    func testSilentBundledAndFallbackPagesRetryOnlyOnceAtTheInitialDeadline() {
        let bundled = URL(fileURLWithPath: "/synthetic/preview/index.html")
        for index in [nil, bundled] as [URL?] {
            let fixture = InitialReadinessTestFixture(index: index)
            defer { fixture.controller.invalidate() }
            XCTAssertEqual(fixture.page.loads.count, 1)
            XCTAssertEqual(fixture.page.loads[0], index)
            XCTAssertEqual(fixture.clock.deadlines.map(\.delay), [2_500_000_000])
            let firstGeneration = fixture.controller.pageLoadGeneration

            fixture.clock.fire()

            XCTAssertEqual(fixture.page.loads.count, 2)
            XCTAssertEqual(fixture.page.loads[1], index)
            XCTAssertNotEqual(fixture.controller.pageLoadGeneration, firstGeneration)
            XCTAssertFalse(fixture.controller.isReady)
            XCTAssertTrue(fixture.clock.deadlines[0].isCancelled)
            fixture.clock.fire()
            fixture.controller.startInitialReadinessWatchdog()
            XCTAssertEqual(fixture.page.loads.count, 2)
            XCTAssertEqual(fixture.clock.deadlines.count, 1)
        }
    }

    func testLegalReadyBeforeTheDeadlineCancelsItPermanently() {
        let fixture = InitialReadinessTestFixture()
        defer { fixture.controller.invalidate() }
        fixture.controller.receive(InitialReadinessTestFixture.ready)
        XCTAssertTrue(fixture.controller.isReady)
        XCTAssertTrue(fixture.clock.deadlines[0].isCancelled)

        fixture.clock.fire()
        fixture.controller.startInitialReadinessWatchdog()

        XCTAssertEqual(fixture.page.loads.count, 1)
        XCTAssertEqual(fixture.clock.deadlines.count, 1)
        XCTAssertTrue(fixture.controller.isReady)
    }

    func testWrongProtocolCannotCancelTheInitialRetry() {
        let fixture = InitialReadinessTestFixture()
        defer { fixture.controller.invalidate() }
        let wrong = PreviewBridge.protocolVersion + 1
        fixture.controller.receive(.ready(ReadyPayload(protocolVersion: wrong)))
        fixture.controller.receiveReadinessProbe(wrong, generation: fixture.controller.pageLoadGeneration)
        XCTAssertFalse(fixture.controller.isReady)
        XCTAssertFalse(fixture.clock.deadlines[0].isCancelled)

        fixture.clock.fire()

        XCTAssertEqual(fixture.page.loads.count, 2)
        XCTAssertFalse(fixture.controller.isReady)
    }

    func testRetriedPageRequiresItsOwnProbeBeforeFlushingTheExactQueuedExport() async throws {
        let fixture = InitialReadinessTestFixture()
        let controller = fixture.controller
        defer { controller.invalidate() }
        let root = URL(fileURLWithPath: "/synthetic/site", isDirectory: true)
        let file = root.appendingPathComponent("posts/latest.md")
        controller.setWorkspaceAssetRoot(root)
        controller.setPresentedDocumentIdentifier("document")
        let olderID = controller.renderForTesting(InitialReadinessTestFixture.change("older", file: file))
        let export = Task { await controller.renderForExport(
            InitialReadinessTestFixture.change("newest queued export", version: 2, file: file)
        ) }
        defer { export.cancel() }
        try await PreviewHostedTestWait.until("queued exact export") { controller.pendingExportRender != nil }
        let request = try XCTUnwrap(controller.renderDispatch.pending)
        let exportID = try XCTUnwrap(controller.pendingExportRender?.renderID)
        let oldGeneration = controller.pageLoadGeneration
        var scrollResults: [Bool] = []
        controller.scrollToLine(8, animated: false, documentIdentifier: "document") { scrollResults.append($0) }
        XCTAssertGreaterThan(exportID, olderID)

        fixture.clock.fire()
        // Both a queued message from the old page and its delayed JS probe are stale.
        controller.receive(InitialReadinessTestFixture.ready)
        controller.receiveReadinessProbe(PreviewBridge.protocolVersion, generation: oldGeneration)
        controller.receiveReadinessProbe(PreviewBridge.protocolVersion + 1, generation: controller.pageLoadGeneration)

        XCTAssertFalse(controller.isReady)
        XCTAssertTrue(fixture.page.renderedPayloads.isEmpty)
        XCTAssertEqual(controller.pendingExportRender?.renderID, exportID)
        XCTAssertEqual(controller.renderDispatch.pending?.renderID, request.renderID)
        XCTAssertEqual(controller.renderDispatch.pending?.change.text, "newest queued export")
        XCTAssertEqual(controller.renderDispatch.pending?.baseDir, "posts")
        XCTAssertEqual(controller.renderDispatch.pending?.assetRootID, request.assetRootID)
        XCTAssertEqual(controller.exportSourceText, "newest queued export")
        XCTAssertTrue(scrollResults.isEmpty)
        XCTAssertEqual(controller.nextExportID, 0)

        controller.receiveReadinessProbe(PreviewBridge.protocolVersion, generation: controller.pageLoadGeneration)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(fixture.page.renderedPayloads.map(\.renderID), [exportID])
        XCTAssertEqual(fixture.page.renderedPayloads.first?.text, request.change.text)
        XCTAssertEqual(fixture.page.renderedPayloads.first?.assetRootID, request.assetRootID)
        controller.receive(.renderComplete(RenderCompletePayload(renderID: olderID, version: 1, blockCount: 1)))
        XCTAssertEqual(controller.pendingExportRender?.renderID, exportID)
        XCTAssertTrue(scrollResults.isEmpty)
        controller.receive(.renderComplete(RenderCompletePayload(renderID: exportID, version: 2, blockCount: 1)))
        let result = await export.value
        XCTAssertEqual(result, .completed(renderID: exportID))
        XCTAssertEqual(controller.scrollDeliveryState.completedRenderID, exportID)
        XCTAssertEqual(scrollResults, [true])
        XCTAssertNil(controller.pendingExportRender)
        fixture.clock.fire()
        controller.startInitialReadinessWatchdog()
        XCTAssertEqual(fixture.page.loads.count, 2)
        XCTAssertEqual(fixture.clock.deadlines.count, 1)
        XCTAssertEqual(
            controller.renderForTesting(InitialReadinessTestFixture.change("next", version: 3)),
            exportID + 1
        )
    }

    func testInvalidationRejectsLateDeadlineReadyAndOldPageProbe() {
        let fixture = InitialReadinessTestFixture()
        let generation = fixture.controller.pageLoadGeneration
        fixture.controller.invalidate()

        fixture.clock.fire()
        fixture.controller.receiveReadinessProbe(PreviewBridge.protocolVersion, generation: generation)
        fixture.controller.receive(InitialReadinessTestFixture.ready)
        fixture.controller.startInitialReadinessWatchdog()

        XCTAssertFalse(fixture.controller.isReady)
        XCTAssertTrue(fixture.clock.deadlines[0].isCancelled)
        XCTAssertEqual(fixture.page.loads.count, 1)
        XCTAssertEqual(fixture.clock.deadlines.count, 1)
    }

    func testTerminationKeepsQueuedExportFailureTerminalDespiteLateInitialCallbacks() async throws {
        let fixture = InitialReadinessTestFixture()
        let controller = fixture.controller
        defer { controller.invalidate() }
        let export = Task { await controller.renderForExport(InitialReadinessTestFixture.change("kept source")) }
        defer { export.cancel() }
        try await PreviewHostedTestWait
            .until("queued export before termination") { controller.pendingExportRender != nil }
        let renderID = try XCTUnwrap(controller.pendingExportRender?.renderID)
        let generation = controller.pageLoadGeneration

        controller.webViewWebContentProcessDidTerminate(controller.webView)
        let result = await export.value
        fixture.clock.fire()
        controller.receiveReadinessProbe(PreviewBridge.protocolVersion, generation: generation)

        XCTAssertEqual(result, .failed(reason: "web-content-process-terminated", renderID: renderID))
        XCTAssertNil(controller.pendingExportRender)
        XCTAssertFalse(controller.isReady)
        XCTAssertTrue(controller.webContentProcessTerminated)
        XCTAssertEqual(fixture.page.loads.count, 1)
        XCTAssertTrue(fixture.clock.deadlines[0].isCancelled)
    }

    func testLiveTerminationRecoveryDoesNotGainAnExtraInitialRetry() {
        let fixture = InitialReadinessTestFixture(recoversFromTermination: true)
        let controller = fixture.controller
        defer { controller.invalidate() }
        _ = controller.renderForTesting(InitialReadinessTestFixture.change("latest source"))
        for _ in 0 ... PreviewController.maximumConsecutiveRecoveries {
            controller.webViewWebContentProcessDidTerminate(controller.webView)
        }
        XCTAssertEqual(fixture.page.loads.count, 1 + PreviewController.maximumConsecutiveRecoveries)
        XCTAssertTrue(controller.webContentProcessTerminated)
        fixture.clock.fire()
        XCTAssertEqual(fixture.page.loads.count, 1 + PreviewController.maximumConsecutiveRecoveries)
        XCTAssertEqual(fixture.clock.deadlines.count, 1)

        _ = controller.renderForTesting(InitialReadinessTestFixture.change("new edit", version: 2))
        XCTAssertEqual(fixture.page.loads.count, 2 + PreviewController.maximumConsecutiveRecoveries)
        fixture.clock.fire()
        XCTAssertEqual(fixture.page.loads.count, 2 + PreviewController.maximumConsecutiveRecoveries)
    }

    func testCancelledDeadlineCannotReloadAnActiveHTMLExport() async throws {
        let fixture = InitialReadinessTestFixture()
        let controller = fixture.controller
        defer { controller.invalidate() }
        controller.receive(InitialReadinessTestFixture.ready)
        let renderID = controller.renderForTesting(InitialReadinessTestFixture.change("export source"))
        controller.receive(.renderComplete(RenderCompletePayload(renderID: renderID, version: 1, blockCount: 1)))
        let export = Task { await controller.exportHTML(matchingRenderID: renderID) }
        defer { export.cancel() }
        try await PreviewHostedTestWait.until("active HTML export") { controller.pendingHTMLExport != nil }
        let exportID = try XCTUnwrap(controller.pendingHTMLExport?.exportID)

        fixture.clock.fire()

        XCTAssertEqual(fixture.page.loads.count, 1)
        XCTAssertEqual(controller.pendingHTMLExport?.exportID, exportID)
        XCTAssertEqual(controller.nextExportID, exportID + 1)
        controller.failPendingHTMLExport(reason: "test-complete")
        let result = await export.value
        XCTAssertEqual(result, .failed(reason: "test-complete", exportID: exportID, renderID: renderID))
    }

    func testDeadlineCallbackDoesNotRetainItsController() {
        let clock = InitialReadinessTestClock()
        let page = InitialReadinessTestPage()
        var controller: PreviewController? = PreviewController(
            previewIndexURL: nil,
            retriesSilentInitialLoad: true,
            initialReadinessScheduler: clock.schedule,
            pageLoadOverrideForTesting: page.load
        )
        weak var releasedController = controller
        defer { releasedController?.invalidate() }

        controller = nil

        XCTAssertNil(releasedController)
        clock.fire()
        XCTAssertEqual(page.loads.count, 1)
    }

    func testSynchronousDeadlineInstallationStillSpendsTheRetryBeforeReloading() {
        let page = InitialReadinessTestPage()
        var captured: (@MainActor () -> Void)?
        var cancellations = 0
        let controller = PreviewController(
            previewIndexURL: nil,
            retriesSilentInitialLoad: true,
            initialReadinessScheduler: { _, fire in
                captured = fire
                fire()
                return { cancellations += 1 }
            },
            pageLoadOverrideForTesting: page.load
        )
        defer { controller.invalidate() }

        captured?()
        controller.startInitialReadinessWatchdog()

        XCTAssertEqual(page.loads.count, 2)
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(controller.isReady)
    }
}
