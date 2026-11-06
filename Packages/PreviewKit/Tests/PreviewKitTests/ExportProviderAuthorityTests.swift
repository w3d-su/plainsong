import MarkdownCore
@testable import PreviewKit
import WebKit
import XCTest

/// Serves only the grant it was built for, like the iOS access service's `matchingRecord`.
/// A Mac-style context (random root token, fixed Mac grant identity) is refused.
final class GrantMatchingAssetReader: PreviewAssetReading, @unchecked Sendable {
    let expected: PreviewAssetAccessContext
    private let lock = NSLock()
    private var requests: [PreviewAssetReadRequest] = []

    init(expected: PreviewAssetAccessContext) {
        self.expected = expected
    }

    var recorded: [PreviewAssetReadRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func read(_ request: PreviewAssetReadRequest) async throws -> PreviewAssetReadResult {
        lock.lock()
        requests.append(request)
        lock.unlock()
        guard AssetAuthority.matches(request.access, expected) else {
            throw PreviewAssetReadFailure.accessChanged
        }
        let data = try Data(contentsOf: request.resolvedURL)
        return PreviewAssetReadResult(
            requestID: request.requestID,
            coordinatedURL: request.resolvedURL,
            bytes: data,
            access: request.access
        )
    }
}

/// iOS export (B1): HTML embedding and the DOM a PDF captures both use the scene's grant
/// authority, not a Mac root context the iOS reader cannot match.
@MainActor
final class ExportProviderAuthorityTests: XCTestCase {
    func testDirectoryGrantExportEmbedsLocalImagesThroughTheReader() async throws {
        let root = try makeWorkspace()
        let access = PreviewAssetTestSupport.access(root: root, generation: 3)
        let reader = GrantMatchingAssetReader(expected: access)
        let controller = try makeController(reader: reader)

        let result = try await export(controller, root: root, access: access)

        XCTAssertEqual(result.omittedImageCount, 0)
        guard case let .ready(html, _, _) = result else { return XCTFail("Expected ready HTML") }
        XCTAssertTrue(html.contains("data:image/png;base64,"))
        XCTAssertFalse(reader.recorded.isEmpty)
        XCTAssertTrue(reader.recorded.allSatisfy { AssetAuthority.matches($0.access, access) })
        // The live DOM is what PDF and Print capture: the image decoded through the reader.
        try await PreviewHostedTestWait.until("export DOM image decoded", timeoutNanoseconds: 8_000_000_000) {
            let loaded = try await controller.webView.evaluateJavaScript(
                "Array.from(document.querySelectorAll('img')).filter(i => i.complete && i.naturalWidth > 0).length"
            ) as? Int
            return loaded == 1
        }
    }

    func testRevokedGrantOmitsTheImageWithoutADirectDiskRead() async throws {
        let root = try makeWorkspace()
        let current = PreviewAssetTestSupport.access(root: root, generation: 4)
        let stale = PreviewAssetTestSupport.access(root: root, generation: 3)
        let reader = GrantMatchingAssetReader(expected: current)
        let controller = try makeController(reader: reader)

        let result = try await export(controller, root: root, access: stale)

        // The file is on disk and inside the root; only the reader may serve it.
        XCTAssertEqual(result.omittedImageCount, 1)
        XCTAssertFalse(reader.recorded.isEmpty)
    }

    func testSingleFileGrantDoesNotPromoteTheParentFolder() async throws {
        let root = try makeWorkspace()
        let reader = GrantMatchingAssetReader(
            expected: PreviewAssetTestSupport.access(root: root, generation: 1)
        )
        let controller = try makeController(reader: reader)

        let result = try await export(controller, root: root, access: nil)

        XCTAssertEqual(result.omittedImageCount, 1)
        XCTAssertTrue(reader.recorded.isEmpty)
    }

    private func export(
        _ controller: PreviewController,
        root: URL,
        access: PreviewAssetAccessContext?
    ) async throws -> PreviewHTMLExportResult {
        let render = await controller.renderForExport(
            DocumentTextChange(
                text: "# Grant\n\n![pixel](assets/x.png)\n",
                version: 1,
                fileKind: .markdown,
                fileURL: root.appendingPathComponent("posts/post.md")
            ),
            assetAccess: access
        )
        guard case let .completed(renderID) = render else {
            XCTFail("Expected a completed render, got \(render)")
            throw CancellationError()
        }
        return await controller.exportHTML(matchingRenderID: renderID)
    }

    private func makeController(reader: GrantMatchingAssetReader) throws -> PreviewController {
        let controller = try PreviewController(previewIndexURL: PreviewBundleFixture.indexURL())
        addTeardownBlock { @MainActor [controller] in controller.invalidate() }
        controller.exportTimeoutNanoseconds = 30_000_000_000
        controller.installAssetReader(reader)
        controller.setAllowsRemoteImages(false)
        controller.setTheme("light")
        return controller
    }

    private func makeWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("plainsong-grant-export-\(UUID().uuidString)", isDirectory: true)
        let assets = root.appendingPathComponent("posts/assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try ExportRasterFixture.encoded(.png).write(to: assets.appendingPathComponent("x.png"))
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }
}
