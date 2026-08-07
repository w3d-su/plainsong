@testable import PreviewKit
import XCTest

final class PreviewScrollDeliveryTests: XCTestCase {
    @MainActor
    func testScrollCompletionReportsJavaScriptDelivery() async throws {
        var controller: PreviewController? = try PreviewController(
            previewIndexURL: previewIndexFixtureURL()
        )
        weak let weakController = controller
        weak let weakWebView = controller?.webView
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
            weakController == nil && weakWebView == nil
        }
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

    @MainActor
    private func waitUntil(
        _ description: String,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }
}
