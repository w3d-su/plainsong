import MarkdownCore
@testable import PreviewKit
import XCTest

/// Shared operations register cleanup on the active test case, never a second XCTestCase.
@MainActor
struct ExportHTMLTestSupport {
    let owner: XCTestCase

    func makeController() throws -> PreviewController {
        let controller = try PreviewController(previewIndexURL: previewIndexFixtureURL())
        owner.addTeardownBlock { @MainActor [weak controller] in controller?.invalidate() }
        return controller
    }

    func render(
        _ controller: PreviewController,
        text: String,
        fileKind: FileKind,
        version: Int
    ) async throws -> Int {
        try await waitUntil("preview bridge ready") {
            controller.isReady
        }

        let renderID = controller.renderForTesting(
            DocumentTextChange(
                text: text,
                version: version,
                fileKind: fileKind,
                fileURL: nil
            )
        )
        try await waitUntil("render \(renderID) completed") {
            controller.scrollDeliveryState.completedRenderID == renderID
        }
        return renderID
    }

    func previewIndexFixtureURL() throws -> URL {
        try PreviewBundleFixture.indexURL()
    }

    func waitUntil(
        _ description: String,
        timeoutNanoseconds: UInt64 = 8_000_000_000,
        condition: @escaping @MainActor () async throws -> Bool
    ) async throws {
        try await PreviewHostedTestWait.until(
            description,
            timeoutNanoseconds: timeoutNanoseconds,
            condition: condition
        )
    }
}
