import MarkdownCore
@testable import PreviewKit
import XCTest

final class PreviewScrollDeliveryTests: XCTestCase {
    @MainActor
    func testScrollCompletionReportsJavaScriptDelivery() async throws {
        var controller: PreviewController? = try PreviewController(
            previewIndexURL: previewIndexFixtureURL()
        )
        let weakController = WeakBox(controller)
        let weakWebView = WeakBox(controller?.webView)
        try await waitUntil("preview bridge ready") {
            controller?.isReady == true
        }
        let delivered = expectation(description: "scroll JavaScript delivered")
        var succeeded = false

        controller?.scrollToLine(1, animated: false) { result in
            succeeded = result
            delivered.fulfill()
        }

        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertTrue(succeeded)
        controller?.shutdownForTesting()
        controller = nil
        try await waitUntil("preview controller and WebView deallocate") {
            weakController.value == nil && weakWebView.value == nil
        }
    }

    @MainActor
    func testDocumentNavigationWaitsForMatchingRenderBeforeScrolling() async throws {
        let controller = try PreviewController(previewIndexURL: previewIndexFixtureURL())
        controller.webView.frame = CGRect(x: 0, y: 0, width: 640, height: 300)
        let documentIdentifier = "document-a"
        let document = makeLongDocument(target: "MATCHING_RENDER_TARGET")
        var completedRenderIDs: [Int] = []
        controller.renderCompletionObserver = { completedRenderIDs.append($0.renderID) }

        controller.setPresentedDocumentIdentifier(documentIdentifier)
        let renderID = controller.renderForTesting(
            DocumentTextChange(
                text: document.source,
                version: 1,
                fileKind: .markdown,
                fileURL: nil
            )
        )
        let delivered = expectation(description: "scroll delivered after render")
        var deliverySucceeded = false
        controller.scrollToLine(
            document.targetLine,
            animated: false,
            documentIdentifier: documentIdentifier
        ) { succeeded in
            deliverySucceeded = succeeded
            delivered.fulfill()
        }

        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertTrue(deliverySucceeded)
        XCTAssertTrue(completedRenderIDs.contains(renderID))
        try await waitUntil("matching rendered target is visible after queued navigation") {
            let script = """
            (() => {
              const target = document.querySelector('[data-line="\(document.targetLine)"]');
              if (!target) return false;
              const rect = target.getBoundingClientRect();
              return window.scrollY > 0 && rect.bottom > 0 && rect.top < window.innerHeight;
            })()
            """
            return try await controller.webView.evaluateJavaScript(script) as? Bool == true
        }
        controller.shutdownForTesting()
    }

    @MainActor
    func testPendingDocumentNavigationFailsInsteadOfReplayingIntoAnotherDocument() async throws {
        let controller = try PreviewController(previewIndexURL: previewIndexFixtureURL())
        let firstDocumentIdentifier = "document-a"
        let secondDocumentIdentifier = "document-b"
        var deliveryResult: Bool?

        controller.setPresentedDocumentIdentifier(firstDocumentIdentifier)
        _ = controller.renderForTesting(
            DocumentTextChange(
                text: makeLongDocument(target: "FIRST_TARGET").source,
                version: 1,
                fileKind: .markdown,
                fileURL: nil
            )
        )
        controller.scrollToLine(
            200,
            animated: false,
            documentIdentifier: firstDocumentIdentifier
        ) { deliveryResult = $0 }
        XCTAssertNil(deliveryResult)

        controller.setPresentedDocumentIdentifier(secondDocumentIdentifier)
        _ = controller.renderForTesting(
            DocumentTextChange(
                text: "# Second document\n\nNo stale target here.",
                version: 0,
                fileKind: .markdown,
                fileURL: nil
            )
        )

        XCTAssertEqual(deliveryResult, false)
        try await waitUntil("second document renders without stale navigation") {
            let text = try await controller.webView.evaluateJavaScript("document.body.innerText") as? String
            return text?.contains("Second document") == true
        }
        let evaluatedScrollY = try await controller.webView.evaluateJavaScript("window.scrollY") as? Double
        let scrollY = try XCTUnwrap(evaluatedScrollY)
        XCTAssertEqual(scrollY, 0, accuracy: 0.5)
        controller.shutdownForTesting()
    }

    @MainActor
    func testUnboundNavigationFailsWhenPresentedDocumentChangesBeforeRender() throws {
        let controller = try PreviewController(previewIndexURL: previewIndexFixtureURL())
        let firstDocumentIdentifier = "document-a"
        var deliveryResult: Bool?

        controller.setPresentedDocumentIdentifier(firstDocumentIdentifier)
        controller.scrollToLine(
            200,
            animated: false,
            documentIdentifier: firstDocumentIdentifier
        ) { deliveryResult = $0 }
        XCTAssertNil(deliveryResult)

        controller.setPresentedDocumentIdentifier("document-b")

        XCTAssertEqual(deliveryResult, false)
        controller.shutdownForTesting()
    }

    private func previewIndexFixtureURL() throws -> URL {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repositoryRoot
            .appendingPathComponent("App/Resources/preview/index.html")
            .standardizedFileURL
    }

    private func makeLongDocument(target: String) -> (source: String, targetLine: Int) {
        var lines = ["# Preview scroll race", ""]
        lines += (1 ... 180).flatMap { ["Paragraph before \($0)", ""] }
        let targetLine = lines.count + 1
        lines.append(target)
        lines.append("")
        lines += (1 ... 20).flatMap { ["Paragraph after \($0)", ""] }
        return (lines.joined(separator: "\n"), targetLine)
    }

    @MainActor
    private func waitUntil(
        _ description: String,
        condition: @escaping @MainActor () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }
}

private final class WeakBox<Object: AnyObject> {
    weak var value: Object?

    init(_ value: Object?) {
        self.value = value
    }
}
