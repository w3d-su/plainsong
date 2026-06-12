import AppKit
import MarkdownCore
@testable import PreviewKit
import XCTest

final class PreviewKitTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertFalse(PreviewKitInfo.version.isEmpty)
    }

    func testBridgeProtocolVersionAndMessageOrder() {
        XCTAssertEqual(PreviewBridge.protocolVersion, 3)
        XCTAssertEqual(
            BridgeMessageName.allCases.map(\.rawValue),
            [
                "ready",
                "render",
                "renderComplete",
                "scrollToLine",
                "previewScrolled",
                "linkClicked",
                "checkboxToggled",
                "setTheme",
            ]
        )
    }

    func testBridgeMessageRoundTrip() throws {
        let message = BridgeMessage.checkboxToggled(
            CheckboxToggledPayload(line: 12, checked: true, version: 42)
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(BridgeMessage.self, from: data)

        XCTAssertEqual(decoded, message)
    }

    func testPreviewNavigationPolicyOnlyAllowsBundledIndex() {
        let indexURL = URL(fileURLWithPath: "/tmp/Plainsong.app/Contents/Resources/preview/index.html")

        XCTAssertEqual(
            PreviewController.navigationPolicy(for: indexURL, previewIndexURL: indexURL),
            .allow
        )
        XCTAssertEqual(
            PreviewController.navigationPolicy(
                for: URL(fileURLWithPath: "/tmp/Plainsong.app/Contents/Resources/preview/other.html"),
                previewIndexURL: indexURL
            ),
            .cancel
        )
        XCTAssertEqual(
            PreviewController.navigationPolicy(for: URL(string: "https://example.com"), previewIndexURL: indexURL),
            .cancel
        )
    }

    @MainActor
    func testPreviewControllerUsesTransparentWebViewBackground() {
        let controller = PreviewController()

        XCTAssertEqual(controller.webView.layer?.backgroundColor, NSColor.clear.cgColor)
    }

    @MainActor
    func testPreviewControllerLoadsPreviewBundleAndRendersMarkdown() async throws {
        let controller = try PreviewController(previewIndexURL: previewIndexFixtureURL())

        try await waitUntil("preview bridge ready") {
            controller.isReady
        }

        controller.render(
            DocumentTextChange(
                text: """
                # Preview smoke

                - [ ] task
                """,
                version: 1,
                fileKind: .markdown,
                fileURL: nil
            )
        )

        try await waitUntil("rendered markdown visible") {
            let text = try await controller.webView.evaluateJavaScript("document.body.innerText") as? String
            return text?.contains("Preview smoke") == true && text?.contains("task") == true
        }
    }

    func testAssetResolverAllowsContainedPaths() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resolver = AssetURLResolver(allowedRoot: root)

        let resolved = try resolver.resolve(XCTUnwrap(URL(string: "asset://images/photo.png")))

        XCTAssertEqual(
            resolved,
            root.appendingPathComponent("images/photo.png").standardizedFileURL
        )
    }

    func testAssetResolverRejectsParentDirectoryEscapes() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resolver = AssetURLResolver(allowedRoot: root)

        XCTAssertThrowsError(
            try resolver.resolve(XCTUnwrap(URL(string: "asset://../secret.png")))
        ) { error in
            XCTAssertEqual(error as? AssetURLResolverError, .pathEscapesRoot)
        }
    }

    func testAssetResolverRejectsEncodedTraversalEscapes() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resolver = AssetURLResolver(allowedRoot: root)

        XCTAssertThrowsError(
            try resolver.resolve(XCTUnwrap(URL(string: "asset://%2e%2e/secret.png")))
        ) { error in
            XCTAssertEqual(error as? AssetURLResolverError, .pathEscapesRoot)
        }
    }

    func testAssetResolverRejectsHostOnlyEscapes() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resolver = AssetURLResolver(allowedRoot: root)

        XCTAssertThrowsError(
            try resolver.resolve(XCTUnwrap(URL(string: "asset://..")))
        ) { error in
            XCTAssertEqual(error as? AssetURLResolverError, .pathEscapesRoot)
        }
    }

    private func previewIndexFixtureURL() throws -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let indexURL = repositoryRoot
            .appendingPathComponent("App/Resources/preview/index.html")
            .standardizedFileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path), "Missing preview bundle fixture")
        return indexURL
    }

    @MainActor
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
