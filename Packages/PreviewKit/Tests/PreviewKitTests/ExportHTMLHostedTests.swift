#if os(macOS)
    import AppKit
#endif
import MarkdownCore
@testable import PreviewKit
import XCTest

@MainActor
final class ExportHTMLHostedTests: XCTestCase {
    private var support: ExportHTMLTestSupport {
        ExportHTMLTestSupport(owner: self)
    }

    func testSuccessfulMarkdownExportIsAStaticDocument() async throws {
        let controller = try support.makeController()
        defer { controller.invalidate() }
        let renderID = try await support.render(
            controller,
            text: """
            ---
            title: Hidden Frontmatter
            ---

            # Export Heading

            - [ ] a task

            [Safe](https://example.com)
            """,
            fileKind: .markdown,
            version: 11
        )

        let result = await controller.exportHTML(matchingRenderID: renderID)
        guard case let .ready(html, exportID, exportedRenderID) = result else {
            return XCTFail("Expected ready HTML, got \(result)")
        }

        XCTAssertEqual(exportedRenderID, renderID)
        XCTAssertGreaterThanOrEqual(exportID, 0)
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("Export Heading"))
        XCTAssertTrue(html.contains("https://example.com"))
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(html.contains("script-src 'none'"))
        XCTAssertTrue(html.contains("id=\"preview-root\""))
        XCTAssertTrue(html.contains("<title>Hidden Frontmatter</title>"))
        XCTAssertFalse(try XCTUnwrap(html.components(separatedBy: "<body>").last?.contains("Hidden Frontmatter")))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("bundle.js"))
        XCTAssertFalse(html.contains("asset://"))
        XCTAssertFalse(html.contains("webkit.messageHandlers"))
        XCTAssertTrue(
            html.contains("--preview-bg"),
            "PR C must embed the already-loaded preview stylesheet, not an empty style tag."
        )
    }

    func testMDXPlaceholdersExportWithoutComponentExecution() async throws {
        let controller = try support.makeController()
        defer { controller.invalidate() }
        let renderID = try await support.render(
            controller,
            text: """
            import Button from "./Button"

            # MDX Export

            <Button tone="info">**Child**</Button>
            """,
            fileKind: .mdx,
            version: 12
        )

        let result = await controller.exportHTML(matchingRenderID: renderID)
        guard case let .ready(html, _, _) = result else {
            return XCTFail("Expected ready HTML, got \(result)")
        }

        XCTAssertTrue(html.contains("MDX Export"))
        XCTAssertTrue(html.contains("mdx-esm-placeholder") || html.contains("⟨import Button"))
        XCTAssertTrue(html.contains("mdx-component-card") || html.contains("Button"))
        XCTAssertFalse(html.contains("<script"))
    }

    func testMDXSyntaxErrorFailsInsteadOfExportingLastGoodDOM() async throws {
        let controller = try support.makeController()
        defer { controller.invalidate() }
        let goodRenderID = try await support.render(
            controller,
            text: "# Good MDX\n",
            fileKind: .mdx,
            version: 13
        )
        let good = await controller.exportHTML(matchingRenderID: goodRenderID)
        guard case .ready = good else {
            return XCTFail("Expected a successful baseline export, got \(good)")
        }

        let failedRenderID = try await support.render(
            controller,
            text: "<Component unclosed",
            fileKind: .mdx,
            version: 14
        )
        let result = await controller.exportHTML(matchingRenderID: failedRenderID)
        guard case let .failed(reason, _, exportedRenderID) = result else {
            return XCTFail("Expected MDX export failure, got \(result)")
        }
        XCTAssertEqual(exportedRenderID, failedRenderID)
        XCTAssertEqual(reason, "mdx-stale-or-error")
    }

    func testStaleRenderIDFailsWithoutEvaluatingOuterHTML() async throws {
        let controller = try support.makeController()
        defer { controller.invalidate() }
        _ = try await support.render(controller, text: "# Current\n", fileKind: .markdown, version: 15)

        let result = await controller.exportHTML(matchingRenderID: 99)
        guard case let .failed(reason, _, _) = result else {
            return XCTFail("Expected stale failure, got \(result)")
        }
        XCTAssertEqual(reason, "stale-or-missing-render")
    }

    func testNewerRenderFailsAPendingExport() async throws {
        let controller = try support.makeController()
        defer { controller.invalidate() }
        let firstRenderID = try await support.render(
            controller,
            text: "# First\n",
            fileKind: .markdown,
            version: 16
        )

        let result = await withCheckedContinuation { continuation in
            controller.pendingHTMLExport = PendingHTMLExport(
                exportID: 7,
                renderID: firstRenderID,
                continuation: continuation
            )
            _ = controller.renderForTesting(
                DocumentTextChange(
                    text: "# Second\n",
                    version: 17,
                    fileKind: .markdown,
                    fileURL: nil
                )
            )
        }
        guard case let .failed(reason, exportID, renderID) = result else {
            return XCTFail("Expected superseded export, got \(result)")
        }
        XCTAssertEqual(reason, "render-superseded")
        XCTAssertEqual(exportID, 7)
        XCTAssertEqual(renderID, firstRenderID)
        XCTAssertNil(controller.pendingHTMLExport)
    }
}
