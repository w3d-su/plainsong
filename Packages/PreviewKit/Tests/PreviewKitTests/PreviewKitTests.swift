import AppKit
import MarkdownCore
@testable import PreviewKit
import XCTest

final class PreviewKitTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertFalse(PreviewKitInfo.version.isEmpty)
    }

    func testBridgeProtocolVersionAndMessageOrder() {
        XCTAssertEqual(PreviewBridge.protocolVersion, 5)
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
        let message = BridgeMessage.render(
            RenderPayload(
                renderID: 1,
                version: 42,
                fileKind: .mdx,
                text: "# Title",
                baseDir: "content",
                theme: "dark",
                allowRemoteImages: true
            )
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(BridgeMessage.self, from: data)

        XCTAssertEqual(decoded, message)
    }

    func testSetThemePayloadCarriesRemoteImagePolicy() throws {
        let message = BridgeMessage.setTheme(SetThemePayload(theme: "dark", allowRemoteImages: true))

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(BridgeMessage.self, from: data)

        XCTAssertEqual(decoded, message)
    }

    /// Regression: switching to a different document whose `version` is lower than
    /// the previously rendered document must still update the preview. `version`
    /// resets to 0 per `DocumentSession`, so the stale-drop key is the monotonic
    /// `renderID`; using `version` stranded the preview on the prior file.
    @MainActor
    func testRenderingLowerVersionDocumentAfterHigherVersionStillUpdates() async throws {
        let controller = try PreviewController(previewIndexURL: previewIndexFixtureURL())

        try await waitUntil("preview bridge ready") {
            controller.isReady
        }

        controller.render(
            DocumentTextChange(
                text: "# First document",
                version: 7,
                fileKind: .markdown,
                fileURL: nil
            )
        )
        try await waitUntil("first document visible") {
            let text = try await controller.webView.evaluateJavaScript("document.body.innerText") as? String
            return text?.contains("First document") == true
        }

        // A freshly opened file starts its version counter at 0 — lower than 7 above.
        controller.render(
            DocumentTextChange(
                text: "# Second document",
                version: 0,
                fileKind: .markdown,
                fileURL: nil
            )
        )
        try await waitUntil("second document visible despite lower version") {
            let text = try await controller.webView.evaluateJavaScript("document.body.innerText") as? String
            return text?.contains("Second document") == true && text?.contains("First document") != true
        }
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

    @MainActor
    func testPreviewControllerLoadsWorkspaceRelativeImageAssets() async throws {
        let workspaceRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let imageDirectory = workspaceRoot.appendingPathComponent("content/images", isDirectory: true)
        let fileURL = workspaceRoot.appendingPathComponent("content/posts/post.md")
        try FileManager.default.createDirectory(
            at: imageDirectory,
            withIntermediateDirectories: true
        )
        try Self.onePixelPNGData.write(to: imageDirectory.appendingPathComponent("pixel.png"))
        try Self.onePixelPNGData.write(to: imageDirectory.appendingPathComponent("spaced pixel.png"))

        let controller = try PreviewController(previewIndexURL: previewIndexFixtureURL())
        controller.setWorkspaceAssetRoot(workspaceRoot)

        try await waitUntil("preview bridge ready") {
            controller.isReady
        }

        controller.render(
            DocumentTextChange(
                text: """
                # Image

                ![Pixel](../images/pixel.png)

                ![Spaced](<../images/spaced pixel.png>)
                """,
                version: 1,
                fileKind: .markdown,
                fileURL: fileURL
            )
        )

        try await waitUntil("workspace image loaded") {
            let naturalWidths = try await controller.webView.evaluateJavaScript(
                "Array.from(document.querySelectorAll('img')).map((image) => image.naturalWidth)"
            ) as? [Int]
            return naturalWidths == [1, 1]
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

    func testAssetResolverDecodesEscapedSpacesInContainedPaths() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resolver = AssetURLResolver(allowedRoot: root)

        let resolved = try resolver.resolve(XCTUnwrap(URL(string: "asset://images/spaced%20pixel.png")))

        XCTAssertEqual(
            resolved,
            root.appendingPathComponent("images/spaced pixel.png").standardizedFileURL
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

    func testAssetResolverRejectsNestedParentDirectoryTraversal() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resolver = AssetURLResolver(allowedRoot: root)

        XCTAssertThrowsError(
            try resolver.resolve(XCTUnwrap(URL(string: "asset://images/../../secret.png")))
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

    func testAssetResolverRejectsSymlinkEscapesRoot() throws {
        let root = try temporaryDirectory()
        let outsideRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideRoot)
        }

        let escapedTarget = outsideRoot.appendingPathComponent("secret.png")
        try Self.onePixelPNGData.write(to: escapedTarget)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.png"),
            withDestinationURL: escapedTarget
        )

        let resolver = AssetURLResolver(allowedRoot: root)

        XCTAssertThrowsError(
            try resolver.resolve(XCTUnwrap(URL(string: "asset://linked.png")))
        ) { error in
            XCTAssertEqual(error as? AssetURLResolverError, .pathEscapesRoot)
        }
    }

    func testAssetPolicyRejectsUnsupportedTypes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let unsupportedFiles = [
            ("vector.svg", "svg"),
            ("scan.tiff", "tiff"),
            ("bitmap.bmp", "bmp"),
            ("note.txt", "txt"),
            ("unknown", ""),
        ]

        for (fileName, pathExtension) in unsupportedFiles {
            let fileURL = root.appendingPathComponent(fileName)
            try Data("unsupported".utf8).write(to: fileURL)

            XCTAssertThrowsError(
                try AssetURLPolicy.loadAsset(at: fileURL),
                fileName
            ) { error in
                XCTAssertEqual(
                    error as? AssetURLPolicyError,
                    .unsupportedType(pathExtension)
                )
            }
        }
    }

    func testAssetPolicyRejectsOversizedFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("too-large.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: nil))
        let fileHandle = try FileHandle(forWritingTo: fileURL)
        try fileHandle.truncate(atOffset: UInt64(AssetURLPolicy.maxAssetBytes + 1))
        try fileHandle.close()

        XCTAssertThrowsError(
            try AssetURLPolicy.loadAsset(at: fileURL)
        ) { error in
            XCTAssertEqual(
                error as? AssetURLPolicyError,
                .fileTooLarge(
                    actualBytes: AssetURLPolicy.maxAssetBytes + 1,
                    maxBytes: AssetURLPolicy.maxAssetBytes
                )
            )
        }
    }

    func testPreviewAssetContextUsesWorkspaceRootAndWorkspaceRelativeBaseDir() {
        let root = URL(fileURLWithPath: "/tmp/site")
        let file = root.appendingPathComponent("content/posts/post.md")

        let context = PreviewController.assetContext(fileURL: file, workspaceRootURL: root)

        XCTAssertEqual(context.allowedRoot, root.standardizedFileURL)
        XCTAssertEqual(context.baseDir, "content/posts")
    }

    func testPreviewAssetContextFallsBackToFileParentWithoutWorkspace() {
        let file = URL(fileURLWithPath: "/tmp/site/content/post.md")

        let context = PreviewController.assetContext(fileURL: file, workspaceRootURL: nil)

        XCTAssertEqual(context.allowedRoot, file.deletingLastPathComponent().standardizedFileURL)
        XCTAssertNil(context.baseDir)
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

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private nonisolated static let onePixelPNGData = Data(base64Encoded: """
    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR42mP8z8BQDwAFgwJ/lD3G7wAAAABJRU5ErkJggg==
    """)!

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
