import AppKit
@testable import Plainsong
@testable import PreviewKit
import WebKit
import XCTest

/// The workspace creates its preview web view on the first preview show
/// (`docs/decisions/2026-10-22-preview-webview-lifecycle.md`).
@MainActor
extension EditorFindHostedGateTests {
    func testSourceOnlyWorkspaceStartsNoWebViewUntilThePreviewShows() async throws {
        let fixture = try makeWorkspaceFixture(files: ["a.md": "# Lazy preview document"])
        let appState = fixture.appState
        appState.setLayoutMode(.sourceOnly)
        appState.openExternalFile(fixture.root)
        try await waitUntil("source-only workspace opens a.md") {
            appState.currentDocument.fileURL?.lastPathComponent == "a.md"
        }
        let host = makeWorkspaceHost(appState: appState)
        registerTeardown(host: host, fixture: fixture)
        let coordinator = try XCTUnwrap(EditorPreviewScrollCoordinator.latestDebugInstance)

        XCTAssertNil(coordinator.previewControllerForTesting, "Source-only layout created a PreviewController")
        XCTAssertNil(firstDescendant(of: WKWebView.self, in: host.window.contentView))

        appState.setLayoutMode(.sourcePreview)
        let webView = try await waitForView(WKWebView.self, in: host.window)
        let controller = try XCTUnwrap(coordinator.previewControllerForTesting)
        XCTAssertTrue(controller.webView === webView)
        try await waitUntil("first show renders the document", timeout: 8) {
            let text = try await webView.evaluateJavaScript("document.body.innerText") as? String
            return text?.contains("Lazy preview document") == true
        }

        // Hiding keeps the one controller and web view; showing again reuses them.
        appState.setLayoutMode(.sourceOnly)
        try await waitUntil("preview pane hides") {
            self.firstDescendant(of: WKWebView.self, in: host.window.contentView) == nil
        }
        XCTAssertTrue(coordinator.previewControllerForTesting === controller)
        appState.setLayoutMode(.sourcePreview)
        let reshown = try await waitForView(WKWebView.self, in: host.window)
        XCTAssertTrue(reshown === webView)
        XCTAssertTrue(coordinator.previewControllerForTesting === controller)
    }
}
