import MarkdownCore
@testable import Plainsong
@testable import PreviewKit
import XCTest

@MainActor
final class PreviewIntegrationTests: XCTestCase {
    func testPreviewControllerLoadsAppBundlePreviewAndRendersMarkdown() async throws {
        let controller = PreviewController()

        try await waitUntil("preview bridge ready") {
            controller.isReady
        }

        controller.render(
            DocumentTextChange(
                text: "# App preview smoke\n\n- [ ] task",
                version: 1,
                fileKind: .markdown,
                fileURL: nil
            )
        )

        try await waitUntil("rendered markdown visible") {
            let text = try await controller.webView.evaluateJavaScript("document.body.innerText") as? String
            return text?.contains("App preview smoke") == true && text?.contains("task") == true
        }
    }

    func testRetainedCheckboxCannotWriteToSameVersionReplacementDocument() async throws {
        let first = DocumentSession(text: "- [ ] first", fileKind: .markdown)
        let replacement = DocumentSession(text: "- [ ] second\n<Component", fileKind: .mdx)
        let appState = AppState(currentDocument: first, shouldRestoreLastOpenedFile: false)
        let controller = PreviewController()
        defer { controller.shutdownForTesting() }
        var callbacks = 0
        controller.onCheckboxToggled = { line, checked, version, session in
            callbacks += 1
            appState.setTaskCheckbox(line: line, checked: checked, version: version, in: session)
        }
        try await waitUntil("preview bridge ready") { controller.isReady }
        controller.render(first.currentTextChange, for: first)
        try await waitUntil("first checkbox visible") {
            try await controller.webView.evaluateJavaScript(
                "document.querySelector('input[data-task-checkbox]') !== null"
            ) as? Bool == true
        }
        XCTAssertEqual(first.version, replacement.version)
        appState.setCurrentDocument(replacement)

        // Before SwiftUI/debounce submits B, A's bridge event still has valid controller provenance.
        // App must reject its exact session identity even though both documents are version zero.
        try await controller.webView.evaluateJavaScript("document.querySelector('input').click(); true;")
        try await waitUntil("old event reached App") { callbacks == 1 }
        XCTAssertEqual(replacement.text, "- [ ] second\n<Component")
        XCTAssertEqual(first.text, "- [ ] first")

        controller.render(replacement.currentTextChange, for: replacement)
        try await waitUntil("MDX error retains old checkbox") {
            try await controller.webView.evaluateJavaScript(
                "document.querySelector('.mdx-error-banner') !== null && document.querySelector('input') !== null"
            ) as? Bool == true
        }
        // Use an acknowledged ordered bridge message as a barrier after the checkbox event.
        var bridgeBarrier = false
        controller.onPreviewScrolled = { _ in bridgeBarrier = true }
        try await controller.webView.evaluateJavaScript("""
        document.querySelector('input').click();
        window.webkit.messageHandlers.bridge.postMessage({name:'previewScrolled',payload:{topVisibleLine:1}});
        true;
        """)
        try await waitUntil("stale click processed") { bridgeBarrier }
        XCTAssertEqual(callbacks, 1, "Old DOM must not inherit the failed render's authority")
        XCTAssertEqual(replacement.text, "- [ ] second\n<Component")

        let current = DocumentSession(text: "- [ ] current", fileKind: .markdown)
        appState.setCurrentDocument(current)
        controller.render(current.currentTextChange, for: current)
        try await waitUntil("current checkbox visible") {
            let text = try await controller.webView.evaluateJavaScript("document.body.innerText") as? String
            return text?.contains("current") == true
        }
        try await controller.webView.evaluateJavaScript("document.querySelector('input').click(); true;")
        try await waitUntil("current checkbox writes back") { current.text == "- [x] current" }
        XCTAssertEqual(callbacks, 2)
        XCTAssertEqual(first.text, "- [ ] first")
        XCTAssertEqual(replacement.text, "- [ ] second\n<Component")
    }

    func testCheckboxRejectsReopenedSessionAtSameURLAndVersion() {
        let url = URL(fileURLWithPath: "/tmp/preview-checkbox-identity.md")
        let original = DocumentSession(text: "- [ ] old", url: url, fileKind: .markdown)
        let reopened = DocumentSession(text: "- [ ] new", url: url, fileKind: .markdown)
        let appState = AppState(currentDocument: reopened, shouldRestoreLastOpenedFile: false)
        appState.setTaskCheckbox(line: 1, checked: true, version: original.version, in: original)
        XCTAssertEqual(reopened.text, "- [ ] new")
        XCTAssertFalse(reopened.isDirty)
    }

    private func waitUntil(
        _ description: String,
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        condition: @escaping @MainActor () async throws -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if try await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }
}
