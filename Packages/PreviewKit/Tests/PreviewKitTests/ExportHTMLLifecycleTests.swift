import AppKit
import MarkdownCore
@testable import PreviewKit
import XCTest

@MainActor
final class ExportHTMLLifecycleTests: XCTestCase {
    private let support = ExportHTMLHostedTests()

    func testCancellationResolvesPendingExportAndReleasesController() async throws {
        try await assertTerminal(reason: "cancelled") { controller, task in
            task.cancel()
            XCTAssertNotNil(controller.pendingHTMLExport)
        }
    }

    func testTimeoutResolvesPendingExportAndReleasesController() async throws {
        try await assertTerminal(reason: "timeout", timeout: 100_000_000) { _, _ in }
    }

    func testInvalidationResolvesPendingExportAndReleasesController() async throws {
        try await assertTerminal(reason: "invalidated") { controller, _ in
            controller.invalidate()
            controller.invalidate()
        }
    }

    func testWebContentTerminationResolvesPendingExportAndReleasesController() async throws {
        try await assertTerminal(reason: "web-content-process-terminated") { controller, _ in
            // Exercise the WKNavigationDelegate notification without killing shared OS helpers.
            controller.webViewWebContentProcessDidTerminate(controller.webView)
            XCTAssertFalse(controller.isReady)
            XCTAssertNil(controller.scrollDeliveryState.completedRenderID)
        }
    }

    func testJavaScriptSendFailureResolvesPendingExport() async throws {
        let controller = try support.makeController()
        defer { controller.invalidate() }
        let renderID = try await support.render(controller, text: "# Send", fileKind: .markdown, version: 1)
        _ = try await controller.webView
            .evaluateJavaScript("window.PlainsongBridge.receive = () => { throw new Error('send'); }; null")
        let result = await controller.exportHTML(matchingRenderID: renderID)
        assertFailure(result, reason: "bridge-send-failed")
        XCTAssertNil(controller.pendingHTMLExport)
    }

    func testAlreadyCancelledTaskNeverStartsExport() async throws {
        let controller = try support.makeController()
        defer { controller.invalidate() }
        let renderID = try await support.render(controller, text: "# Cancel", fileKind: .markdown, version: 1)
        let task = Task { await controller.exportHTML(matchingRenderID: renderID) }
        task.cancel()
        await assertFailure(task.value, reason: "cancelled")
        XCTAssertNil(controller.pendingHTMLExport)
    }

    func testNewExportSupersedesOldAndLateResultCannotCompleteSuccessor() async throws {
        let controller = try support.makeController()
        defer { controller.invalidate() }
        let renderID = try await support.render(controller, text: "# Supersede", fileKind: .markdown, version: 1)
        try await suspendExports(controller)
        let first = Task { await controller.exportHTML(matchingRenderID: renderID) }
        try await support.waitUntil("first pending") { controller.pendingHTMLExport != nil }
        let oldID = try XCTUnwrap(controller.pendingHTMLExport?.exportID)
        let second = Task { await controller.exportHTML(matchingRenderID: renderID) }
        try await support.waitUntil("second pending") { controller.pendingHTMLExport?.exportID != oldID }
        await assertFailure(first.value, reason: "superseded")
        controller.handleExportHTMLResult(.init(exportID: oldID, renderID: renderID, state: .ready(html: "stale")))
        XCTAssertNotNil(controller.pendingHTMLExport)
        controller.failPendingHTMLExport(reason: "cancelled", matchingExportID: oldID)
        XCTAssertNotNil(controller.pendingHTMLExport, "Delayed cancellation must be request-scoped")
        second.cancel()
        await assertFailure(second.value, reason: "cancelled")
        XCTAssertNil(controller.pendingHTMLExport)
    }

    func testNewRenderInvalidatesSharedBarrierBeforeCompletion() async throws {
        let controller = try support.makeController()
        defer { controller.invalidate() }
        let firstID = try await support.render(controller, text: "# First", fileKind: .markdown, version: 1)
        _ = try await controller.webView.evaluateJavaScript("window.PlainsongBridge.receive = () => {}; null")
        let secondID = controller.renderForTesting(.init(
            text: "# Second",
            version: 0,
            fileKind: .markdown,
            fileURL: nil
        ))
        XCTAssertNil(controller.scrollDeliveryState.completedRenderID)
        await assertFailure(controller.exportHTML(matchingRenderID: firstID), reason: "stale-or-missing-render")
        XCTAssertFalse(controller.scrollDeliveryState.recordRenderCompletion(firstID))
        XCTAssertTrue(controller.scrollDeliveryState.recordRenderCompletion(secondID))
        XCTAssertEqual(controller.scrollDeliveryState.completedRenderID, secondID)
    }

    func testReadyBeforeDiscoveryResponseIsRejected() async throws {
        let controller = try support.makeController()
        defer { controller.invalidate() }
        let renderID = try await support.render(controller, text: "# Phase", fileKind: .markdown, version: 1)
        try await suspendExports(controller)
        let task = Task { await controller.exportHTML(matchingRenderID: renderID) }
        try await support.waitUntil("pending") { controller.pendingHTMLExport != nil }
        let pending = try XCTUnwrap(controller.pendingHTMLExport)
        controller.handleExportHTMLResult(.init(
            exportID: pending.exportID,
            renderID: renderID,
            state: .ready(html: "early")
        ))
        await assertFailure(task.value, reason: "invalid-export-phase")
    }

    private func assertTerminal(
        reason: String,
        timeout: UInt64 = 15_000_000_000,
        trigger: (PreviewController, Task<PreviewHTMLExportResult, Never>) -> Void
    ) async throws {
        var controller: PreviewController? = try support.makeController()
        weak var releasedController = controller
        weak var releasedWebView = controller?.webView
        let renderID = try await support.render(controller!, text: "# Lifecycle", fileKind: .markdown, version: 1)
        controller!.exportTimeoutNanoseconds = timeout
        try await suspendExports(controller!)
        var task: Task<PreviewHTMLExportResult, Never>? = Task { [controller = controller!] in
            await controller.exportHTML(matchingRenderID: renderID)
        }
        try await support.waitUntil("pending export") { controller?.pendingHTMLExport != nil }
        trigger(controller!, task!)
        await assertFailure(task!.value, reason: reason)
        XCTAssertNil(controller!.pendingHTMLExport)
        controller!.invalidate()
        task = nil
        controller = nil
        try await support.waitUntil("controller and WebView release") {
            releasedController == nil && releasedWebView == nil
        }
    }

    private func suspendExports(_ controller: PreviewController) async throws {
        _ = try await controller.webView.evaluateJavaScript("""
        const originalReceive = window.PlainsongBridge.receive;
        window.PlainsongBridge.receive = message => {
            if (message.name !== 'exportHTML') originalReceive(message);
        };
        null;
        """)
    }

    private func assertFailure(_ result: PreviewHTMLExportResult, reason: String) {
        guard case let .failed(actual, _, _) = result else {
            return XCTFail("Expected failure: \(result)")
        }
        XCTAssertEqual(actual, reason)
    }
}
