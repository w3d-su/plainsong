import AppKit
import MarkdownCore
@testable import PreviewKit
import XCTest

@MainActor
final class PreviewRenderingRegressionTests: XCTestCase {
    func testSameNamedImagesReloadAcrossSingleFileDirectoriesAndWorkspaceRoots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a", isDirectory: true)
        let second = root.appendingPathComponent("b", isDirectory: true)
        for (directory, width) in [(first, 1), (second, 2)] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 1, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ))
            for x in 0 ..< width {
                bitmap.setColor(.red, atX: x, y: 0)
            }
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("image.png"))
        }
        for workspaceMode in [false, true] {
            let controller = PreviewController()
            defer { controller.shutdownForTesting() }
            try await waitUntil { controller.isReady }
            if workspaceMode { controller.setWorkspaceAssetRoot(first) }
            controller.render(DocumentTextChange(
                text: "# A\n\n![](image.png)", version: 0, fileKind: .markdown,
                fileURL: first.appendingPathComponent("post.md")
            ))
            try await waitUntil { try await self.imageWidth(controller) == 1 }
            let oldSource = try await controller.webView
                .evaluateJavaScript("document.querySelector('img').src") as? String
            if workspaceMode { controller.setWorkspaceAssetRoot(second) }
            controller.render(DocumentTextChange(
                text: "# B\n\n![](image.png)", version: 0, fileKind: .markdown,
                fileURL: second.appendingPathComponent("post.md")
            ))
            try await waitUntil { try await self.imageWidth(controller) == 2 }
            let newSource = try await controller.webView
                .evaluateJavaScript("document.querySelector('img').src") as? String
            XCTAssertNotEqual(newSource, oldSource)
            let heading = try await controller.webView
                .evaluateJavaScript("document.querySelector('h1').textContent") as? String
            XCTAssertEqual(heading, "B")
        }
    }

    func testMdxFractionKeepsMarkdownLayoutAndRejectsUserStyles() async throws {
        let controller = PreviewController()
        defer { controller.shutdownForTesting() }
        try await waitUntil { controller.isReady }
        var completedID: Int?
        controller.renderCompletionObserver = { completedID = $0.renderID }
        let math = "$\\frac{1}{2}$"
        let firstID = controller.renderForTesting(DocumentTextChange(
            text: math,
            version: 0,
            fileKind: .markdown,
            fileURL: nil
        ))
        try await waitUntil { completedID == firstID }
        let measure = """
        (() => {
          const nodes = Array.from(document.querySelectorAll('.katex-html .mord'));
          const numerator = nodes.find(n => n.textContent === '1' && !n.querySelector('.mord'));
          const denominator = nodes.find(n => n.textContent === '2' && !n.querySelector('.mord'));
          return [numerator.getBoundingClientRect().top, denominator.getBoundingClientRect().top];
        })()
        """
        let mdValue = try await controller.webView.evaluateJavaScript(measure)
        let md = try XCTUnwrap(mdValue as? [Double])
        XCTAssertGreaterThan(abs(md[0] - md[1]), 5)
        let secondID = controller.renderForTesting(DocumentTextChange(
            text: math +
                "\n\n<div style=\"position:fixed\"><span style=\"color:red\">Safe</span><script>bad()</script><svg><path>bad</path></svg></div>",
            version: 0, fileKind: .mdx, fileURL: nil
        ))
        try await waitUntil { completedID == secondID }
        let mdxValue = try await controller.webView.evaluateJavaScript(measure)
        let mdx = try XCTUnwrap(mdxValue as? [Double])
        XCTAssertEqual(mdx[1] - mdx[0], md[1] - md[0], accuracy: 0.5)
        let unsafe = try await controller.webView
            .evaluateJavaScript(
                "document.querySelectorAll('#preview-root > div[style], #preview-root > div span[style], #preview-root script, #preview-root > div svg').length"
            ) as? Int
        XCTAssertEqual(unsafe, 0)
    }

    func testHashClickScrollsToHeadingWithoutForwardingAFileOpen() async throws {
        let controller = PreviewController()
        defer { controller.shutdownForTesting() }
        controller.webView.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        var forwardedLinks = [String]()
        controller.onLinkClicked = { forwardedLinks.append($0) }
        try await waitUntil { controller.isReady }
        var completedID: Int?
        controller.renderCompletionObserver = { completedID = $0.renderID }
        let source = "[jump](#target)\n\n" + String(repeating: "Filler paragraph\n\n", count: 100) + "# Target\n\nEnd"
        let renderID = controller.renderForTesting(DocumentTextChange(
            text: source,
            version: 0,
            fileKind: .markdown,
            fileURL: nil
        ))
        try await waitUntil { completedID == renderID }
        try await controller.webView.evaluateJavaScript("document.querySelector('a[href=\"#target\"]').click(); true;")
        try await waitUntil {
            try await controller.webView
                .evaluateJavaScript(
                    "window.scrollY > 0 && document.getElementById('plainsong-heading-target').getBoundingClientRect().top < window.innerHeight"
                ) as? Bool ==
                true
        }
        XCTAssertTrue(forwardedLinks.isEmpty)
    }

    private func imageWidth(_ controller: PreviewController) async throws -> Int? {
        try await controller.webView.evaluateJavaScript("document.querySelector('img')?.naturalWidth ?? 0") as? Int
    }

    private func waitUntil(_ condition: @escaping @MainActor () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for live preview")
        throw CocoaError(.coderInvalidValue)
    }
}
