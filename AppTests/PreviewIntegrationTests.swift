import MarkdownCore
import PreviewKit
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
