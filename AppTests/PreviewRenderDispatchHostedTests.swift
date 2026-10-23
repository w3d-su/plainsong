import AppKit
@testable import Plainsong
@testable import PreviewKit
import WebKit
import XCTest

/// Single-flight preview rendering in the production `WorkspaceWindow`
/// (`docs/decisions/2026-10-22-preview-render-single-flight.md`).
@MainActor
extension EditorFindHostedGateTests {
    /// Showing the pane and switching documents each submit one render: the restarted
    /// `observe(_:)` yields the text the pane has just rendered, and that repeat is dropped.
    func testPreviewShowAndDocumentSwitchSubmitOneRenderEach() async throws {
        let fixture = try makeWorkspaceFixture(files: [
            "a.md": "# Alpha document\n\n- [ ] alpha task",
            "b.md": "# Beta document",
        ])
        let appState = fixture.appState
        appState.setLayoutMode(.sourcePreview)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace opens a.md with an installed capture") {
            appState.currentDocument.fileURL?.lastPathComponent == "a.md"
                && appState.workspaceInstalledCaptureGeneration == appState.workspaceGeneration
        }
        let host = makeWorkspaceHost(appState: appState)
        registerTeardown(host: host, fixture: fixture)
        let controller = try XCTUnwrap(host.previewLifecycle.controllerForShutdown)

        try await waitForPreviewText("Alpha document", in: controller)
        let afterShow = try await settledRenderID(of: controller)

        let second = fixture.root.appendingPathComponent("b.md").standardizedFileURL
        appState.openWorkspaceFile(second)
        try await waitForPreviewText("Beta document", in: controller)
        let afterSwitch = try await settledRenderID(of: controller)
        XCTAssertEqual(afterSwitch, afterShow + 1, "A document switch must submit exactly one render")

        // Hiding and showing the pane keeps the web view and its DOM; the same session
        // and version is not rendered again.
        appState.setLayoutMode(.sourceOnly)
        try await waitUntil("preview pane hides") { !appState.isPreviewVisible }
        appState.setLayoutMode(.sourcePreview)
        try await waitUntil("preview pane shows") { appState.isPreviewVisible }
        try await waitForPreviewText("Beta document", in: controller)
        let afterReshow = try await settledRenderID(of: controller)
        XCTAssertEqual(afterReshow, afterSwitch)

        // Editing still renders through the debounced observer.
        appState.currentDocument.replaceText("# Beta edited")
        try await waitForPreviewText("Beta edited", in: controller)
        let afterEdit = try await settledRenderID(of: controller)
        XCTAssertEqual(afterEdit, afterReshow + 1)
    }

    private func waitForPreviewText(_ text: String, in controller: PreviewController) async throws {
        try await waitUntil("preview shows \(text)", timeout: 8) {
            let body = try await controller.webView.evaluateJavaScript("document.body.innerText") as? String
            return body?.contains(text) == true
        }
    }

    /// The newest submitted render ID once the 150 ms observer debounce has passed and that
    /// render has completed.
    private func settledRenderID(of controller: PreviewController) async throws -> Int {
        try await Task.sleep(nanoseconds: 450_000_000)
        try await waitUntil("newest render completes") {
            controller.scrollDeliveryState.completedRenderID != nil
                && controller.scrollDeliveryState.completedRenderID == controller.previewProvenanceForTesting.renderID
        }
        return try XCTUnwrap(controller.previewProvenanceForTesting.renderID)
    }
}
