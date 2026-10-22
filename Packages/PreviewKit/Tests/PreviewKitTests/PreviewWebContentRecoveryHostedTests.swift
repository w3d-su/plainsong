#if os(macOS)
    import Foundation
    import MarkdownCore
    @testable import PreviewKit
    import WebKit
    import XCTest

    /// WebContent recovery against a real page (`docs/decisions/2026-10-22-preview-webview-lifecycle.md`).
    @MainActor
    final class PreviewWebContentRecoveryHostedTests: XCTestCase {
        func testLivePreviewReloadsAndShowsTheDocumentAfterATermination() async throws {
            let controller = try PreviewController(
                previewIndexURL: PreviewBundleFixture.indexURL(),
                recoversFromWebContentTermination: true
            )
            defer { controller.shutdownForTesting() }
            var completed: [Int] = []
            controller.renderCompletionObserver = { completed.append($0.renderID) }
            try await PreviewHostedTestWait.until("bundle ready", timeoutNanoseconds: 30_000_000_000) {
                controller.isReady
            }

            let shown = controller.renderForTesting(DocumentTextChange(
                text: "# Survives a WebContent crash\n",
                version: 1,
                fileKind: .markdown,
                fileURL: nil
            ))
            try await PreviewHostedTestWait.until("first render") { completed.contains(shown) }

            terminateWebContentProcess(of: controller)
            try await PreviewHostedTestWait.until("re-submitted render completes", timeoutNanoseconds: 30_000_000_000) {
                completed.contains { $0 > shown }
            }
            let text = try await controller.webView.evaluateJavaScript("document.body.innerText") as? String
            XCTAssertTrue(text?.contains("Survives a WebContent crash") == true, "reloaded page: \(text ?? "nil")")
            XCTAssertTrue(controller.isReady)
            XCTAssertFalse(controller.webContentProcessTerminated)
        }

        /// Delivers the delegate call WebKit makes after a WebContent termination. WebKit's
        /// private kill hook does not report the termination to a web view outside a window.
        private func terminateWebContentProcess(of controller: PreviewController) {
            controller.webViewWebContentProcessDidTerminate(controller.webView)
        }
    }
#endif
