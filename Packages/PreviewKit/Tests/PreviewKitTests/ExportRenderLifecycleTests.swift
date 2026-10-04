import AppKit
import MarkdownCore
@testable import PreviewKit
import XCTest

/// Export PR F: `renderForExport(_:)` is the public exact-`renderComplete` wait the App's
/// dedicated offscreen export controller uses before `exportHTML(matchingRenderID:)`.
@MainActor
final class ExportRenderLifecycleTests: XCTestCase {
    private let support = ExportHTMLHostedTests()

    func testRenderQueuedBeforeReadyCompletesAtItsExactIDAndFeedsExportHTML() async throws {
        let controller = try support.makeController()
        defer { controller.invalidate() }
        controller.setAllowsRemoteImages(false)
        controller.setTheme("dark")

        let result = await controller.renderForExport(change("# Exact Export Render\n"))
        guard case let .completed(renderID) = result else {
            return XCTFail("Expected an exact render completion, got \(result)")
        }
        XCTAssertEqual(controller.scrollDeliveryState.completedRenderID, renderID)
        XCTAssertNil(controller.pendingExportRender)

        let export = await controller.exportHTML(matchingRenderID: renderID)
        guard case let .ready(html, _, exportedRenderID) = export else {
            return XCTFail("Expected ready HTML, got \(export)")
        }
        XCTAssertEqual(exportedRenderID, renderID)
        XCTAssertTrue(html.contains("Exact Export Render"))
    }

    func testNewerRenderSupersedesAPendingExportRender() async throws {
        try await assertPendingRenderFails(reason: "render-superseded") { controller, _ in
            _ = controller.renderForTesting(self.change("# Newer\n"))
        }
    }

    func testInvalidationResolvesAPendingExportRender() async throws {
        try await assertPendingRenderFails(reason: "invalidated") { controller, _ in
            controller.invalidate()
        }
    }

    func testCancellationResolvesAPendingExportRender() async throws {
        try await assertPendingRenderFails(reason: "cancelled") { _, task in
            task.cancel()
        }
    }

    func testWebContentTerminationResolvesAPendingExportRender() async throws {
        try await assertPendingRenderFails(reason: "web-content-process-terminated") { controller, _ in
            controller.webViewWebContentProcessDidTerminate(controller.webView)
        }
    }

    func testTimeoutResolvesAPendingExportRender() async throws {
        try await assertPendingRenderFails(reason: "timeout", timeout: 100_000_000) { _, _ in }
    }

    func testInvalidatedControllerRefusesWithoutSubmittingARender() async throws {
        let controller = try support.makeController()
        controller.invalidate()

        let result = await controller.renderForExport(change("# Never\n"))

        XCTAssertEqual(result, .failed(reason: "invalidated", renderID: -1))
        XCTAssertNil(controller.pendingExportRender)
        XCTAssertNil(controller.scrollDeliveryState.completedRenderID)
    }

    private func assertPendingRenderFails(
        reason: String,
        timeout: UInt64 = 15_000_000_000,
        trigger: @escaping @MainActor (PreviewController, Task<PreviewExportRenderResult, Never>) -> Void
    ) async throws {
        let controller = try support.makeController()
        defer { controller.invalidate() }
        controller.exportTimeoutNanoseconds = timeout
        try await support.waitUntil("preview bridge ready") { controller.isReady }
        // Swallow bridge messages so the submitted render can never complete on its own.
        _ = try await controller.webView.evaluateJavaScript("window.PlainsongBridge.receive = () => {}; null")

        let task = Task { await controller.renderForExport(change("# Pending\n")) }
        if reason != "timeout" {
            try await support.waitUntil("pending export render") { controller.pendingExportRender != nil }
            trigger(controller, task)
        }

        let result = await task.value
        guard case let .failed(actualReason, renderID) = result else {
            return XCTFail("Expected \(reason), got \(result)")
        }
        XCTAssertEqual(actualReason, reason)
        XCTAssertGreaterThanOrEqual(renderID, 0)
        XCTAssertNil(controller.pendingExportRender)
    }

    private func change(_ text: String) -> DocumentTextChange {
        DocumentTextChange(text: text, version: 1, fileKind: .markdown, fileURL: nil)
    }
}
