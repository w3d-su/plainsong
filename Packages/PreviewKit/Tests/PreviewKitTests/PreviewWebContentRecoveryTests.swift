import Foundation
import MarkdownCore
@testable import PreviewKit
import XCTest

/// WebContent recovery (`docs/decisions/2026-10-22-preview-webview-lifecycle.md`).
@MainActor
final class PreviewWebContentRecoveryTests: XCTestCase {
    func testLiveControllerResubmitsTheNewestRenderUnderANewID() {
        let harness = RenderDispatchHarness(testCase: self, recoversFromWebContentTermination: true)
        harness.markReady()
        let session = DocumentSession(text: "- [ ] kept")
        harness.controller.render(session.currentTextChange, for: session)
        let shown = harness.sentRenderIDs[0]
        harness.complete(shown)

        harness.controller.webViewWebContentProcessDidTerminate(harness.controller.webView)
        XCTAssertFalse(harness.controller.isReady)
        let resubmitted = try? XCTUnwrap(harness.controller.renderDispatch.pending)
        XCTAssertEqual(resubmitted?.change.text, "- [ ] kept")
        XCTAssertGreaterThan(resubmitted?.renderID ?? -1, shown)
        XCTAssertEqual(harness.controller.previewProvenanceForTesting.renderID, resubmitted?.renderID)
        XCTAssertNotNil(harness.controller.lastSubmittedRender, "The reloaded page will show this presentation")

        harness.markReady()
        XCTAssertEqual(harness.sentRenderIDs.last, resubmitted?.renderID)

        var toggled: [Int] = []
        harness.controller.onCheckboxToggled = { line, _, _, _ in toggled.append(line) }
        harness.controller.receive(.checkboxToggled(CheckboxToggledPayload(
            renderID: shown, line: 1, checked: true, version: session.version
        )))
        XCTAssertTrue(toggled.isEmpty, "The crashed page's render ID no longer writes back")
        harness.controller.receive(.checkboxToggled(CheckboxToggledPayload(
            renderID: resubmitted?.renderID ?? -1, line: 1, checked: true, version: session.version
        )))
        XCTAssertEqual(toggled, [1])
    }

    func testRecoveryStopsAfterConsecutiveTerminationsWithoutACompletedRender() {
        let harness = RenderDispatchHarness(testCase: self, recoversFromWebContentTermination: true)
        harness.markReady()
        _ = harness.controller.renderForTesting(DocumentTextChange(
            text: "crashes", version: 1, fileKind: .markdown, fileURL: nil
        ))
        for _ in 1 ... PreviewController.maximumConsecutiveRecoveries {
            harness.controller.webViewWebContentProcessDidTerminate(harness.controller.webView)
            XCTAssertNotNil(harness.controller.renderDispatch.pending)
            harness.markReady()
        }
        let sentBefore = harness.sentRenderIDs.count
        harness.controller.webViewWebContentProcessDidTerminate(harness.controller.webView)
        XCTAssertNil(harness.controller.renderDispatch.pending, "Recovery gave up")
        harness.markReady()
        XCTAssertEqual(harness.sentRenderIDs.count, sentBefore)

        // A new edit still renders when a page becomes ready, and a completed render
        // re-arms recovery.
        let edit = harness.controller.renderForTesting(DocumentTextChange(
            text: "edited", version: 2, fileKind: .markdown, fileURL: nil
        ))
        XCTAssertEqual(harness.sentRenderIDs.last, edit)
        harness.complete(edit)
        harness.controller.webViewWebContentProcessDidTerminate(harness.controller.webView)
        XCTAssertEqual(harness.controller.renderDispatch.pending?.change.text, "edited")
    }

    func testExportControllersDoNotRecover() {
        let harness = RenderDispatchHarness(testCase: self)
        harness.markReady()
        let renderID = harness.controller.renderForTesting(DocumentTextChange(
            text: "export", version: 1, fileKind: .markdown, fileURL: nil
        ))
        harness.complete(renderID)
        harness.controller.webViewWebContentProcessDidTerminate(harness.controller.webView)
        XCTAssertNil(harness.controller.renderDispatch.pending)
        XCTAssertEqual(harness.controller.previewProvenanceForTesting.renderID, renderID)
    }
}
