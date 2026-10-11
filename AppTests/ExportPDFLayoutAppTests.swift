import AppKit
import MarkdownCore
import PDFKit
@testable import PreviewKit
import XCTest

/// Production Export as PDF… layout: export-only overflow, per-page width and scale,
/// and the A1 variable-height page plan (`docs/export-gates.md` D4).
@MainActor
final class ExportPDFLayoutAppTests: XCTestCase {
    func testWideTableCodeMathAndMermaidStayInsideTheCapture() async throws {
        let columns = (0 ..< 12).map { String(format: "GCOLUMN%02dSENTINEL", $0) }
        let table = Self.tableSource(columns, cell: "value")
        let code = "```\n" + String(repeating: "W", count: 180) + "CODERIGHTSENTINEL\n```\n"
        let math = "$$\n" + (0 ..< 12).map { "\\text{KATEX\($0)SENTINEL}+" }.joined() + "x\n$$\n"
        // A genuinely wide diagram: 30 chained nodes push the rendered SVG several
        // thousand points wide, well past the 800 pt export viewport.
        let mermaidNodes = (0 ..< 30).map {
            "N\($0)[MERMAIDNODE\($0)SENTINEL]"
        }.joined(separator: " --> ")
        let mermaid = "```mermaid\nflowchart LR\n  \(mermaidNodes)\n```\n"
        let source = [table, code, math, mermaid, "AFTERALLSENTINEL"].joined(separator: "\n")
        let (controller, pdf) = try await capture(source)
        defer { controller.invalidate() }
        XCTAssertEqual(pdf.minimumScale, 1, "This fixture must stay under 14,400 pt so no page shrinks")
        XCTAssertLessThanOrEqual(pdf.contentSize.width, ExportPDFPagePlanner.maximumSide + 0.5)
        let text = Self.text(of: pdf.data)
        // The KaTeX and Mermaid sentinels must survive as extractable PDF text, proving
        // the formula and the diagram drew instead of clipping inside the viewport.
        for marker in columns + ["CODERIGHTSENTINEL", "AFTERALLSENTINEL",
                                 "MERMAIDNODE0SENTINEL", "MERMAIDNODE29SENTINEL"]
        {
            XCTAssertEqual(text.components(separatedBy: marker).count - 1, 1, marker)
        }
        // KaTeX emits the formula once in the visible span and once inside the hidden
        // MathML accessibility annotation, so extraction legitimately carries it twice.
        for marker in ["KATEX0SENTINEL", "KATEX11SENTINEL"] {
            XCTAssertGreaterThanOrEqual(
                text.components(separatedBy: marker).count - 1, 1, marker
            )
        }
        let order = columns + ["CODERIGHTSENTINEL", "AFTERALLSENTINEL"]
        var search = text.startIndex
        for marker in order {
            guard let range = text.range(of: marker, range: search ..< text.endIndex) else {
                return XCTFail("Missing \(marker)")
            }
            search = range.upperBound
        }
        // Every selector must exist in the export DOM — a missing one must fail rather
        // than silently skip the edge assertion.
        let edges = try await controller.webView.evaluateJavaScript("""
        (() => {
          const width = Math.max(document.documentElement.scrollWidth, document.body.scrollWidth);
          const box = (selector) => {
            const node = document.querySelector(selector);
            if (!node) return -1;
            const rect = node.getBoundingClientRect();
            return rect.right + window.scrollX;
          };
          return [width, box("table"), box("pre"), box(".plainsong-math-block"), box(".mermaid-rendered")];
        })()
        """)
        let values = try XCTUnwrap(edges as? [Double])
        XCTAssertEqual(values.count, 5)
        for (index, edge) in values.dropFirst().enumerated() {
            XCTAssertGreaterThanOrEqual(edge, 0, "selector \(index) missing from the export DOM")
            XCTAssertLessThanOrEqual(edge, values[0] + 1)
        }
        XCTAssertGreaterThan(values[1], 800, "The table must extend past the 800 pt export viewport")
        XCTAssertGreaterThan(values[4], 800, "The Mermaid diagram must be genuinely wide")
        Self.assertPagesFit(pdf)
    }

    func testWideButFittingCaptureIsNotScaled() async throws {
        // A still-wider table lays out near but below the default user space; the hosted
        // proof that a wide, in-range document stays at scale 1.
        let columns = (0 ..< 200).map { String(format: "C%02d", $0) } + ["SCALERIGHTSENTINEL"]
        let source = Self.tableSource(columns, cell: "x")
        let (controller, pdf) = try await capture(source)
        defer { controller.invalidate() }
        XCTAssertEqual(pdf.minimumScale, 1)
        XCTAssertGreaterThan(pdf.contentSize.width, 10000)
        XCTAssertLessThanOrEqual(pdf.contentSize.width, ExportPDFPagePlanner.maximumSide)
        XCTAssertEqual(Self.text(of: pdf.data).components(separatedBy: "SCALERIGHTSENTINEL").count - 1, 1)
        Self.assertPagesFit(pdf)
        XCTAssertNil(controller.webView.window)
    }

    func testOverMaximumWidthScalesInPDFSpaceWithEveryColumnOnce() async throws {
        // ~25,000 pt wide: the capture runs at full size and the joiner scales down, so
        // scale < 1 while every media box fits the 14,400 pt default user space.
        let columns = (0 ..< 64).map { String(format: "WIDECOLUMN%02dSENTINEL", $0) }
        let source = Self.tableSource(columns, cell: String(repeating: "x", count: 60))
        let (controller, pdf) = try await capture(source)
        defer { controller.invalidate() }
        XCTAssertGreaterThan(pdf.contentSize.width, 20000)
        XCTAssertLessThan(pdf.minimumScale, 1)
        let text = Self.text(of: pdf.data)
        for marker in columns {
            XCTAssertEqual(text.components(separatedBy: marker).count - 1, 1, marker)
        }
        guard let document = PDFDocument(data: pdf.data) else { return XCTFail("empty pdf") }
        for index in 0 ..< document.pageCount {
            let box = document.page(at: index)?.bounds(for: .mediaBox) ?? .zero
            XCTAssertLessThanOrEqual(box.width, 14400.5)
            XCTAssertLessThanOrEqual(box.height, 14400.5)
        }
        Self.assertPagesFit(pdf)
    }

    func testProductionTallCaptureKeepsEverySentinelOnceInOrder() async throws {
        let fixture = ExportPDFMechanismSpikeTests.tallFixture
        let (controller, pdf) = try await capture(fixture.markdown)
        defer { controller.invalidate() }
        XCTAssertGreaterThan(pdf.contentSize.height, 14400)
        XCTAssertGreaterThan(pdf.pageCount, 1)
        XCTAssertLessThanOrEqual(pdf.maximumPageHeight, 14400)
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            fixture.sentinels, in: Self.text(of: pdf.data)
        )
        Self.assertPagesFit(pdf)
        XCTAssertNil(controller.webView.window)
    }

    func testPrintAspectBoundsPageHeightForThePaper() async throws {
        // The B1 path: the same planner with the paper imageable aspect bounds each page.
        let fixture = ExportPDFMechanismSpikeTests.tallFixture
        let controller = try await preparedController(fixture.markdown)
        defer { controller.invalidate() }
        let aspect: CGFloat = 1.294 // ~Letter portrait imageable ratio
        let pdf = try await controller.captureExportPDF(pageAspect: aspect)
        XCTAssertEqual(pdf.droppedTrailingBlankPages, 0)
        XCTAssertGreaterThan(pdf.pageCount, 1)
        let aspectBudget = pdf.contentSize.width * aspect
        XCTAssertLessThanOrEqual(pdf.maximumPageHeight, max(aspectBudget, 0.5) + 0.5)
        guard let document = PDFDocument(data: pdf.data) else { return XCTFail("empty pdf") }
        for index in 0 ..< document.pageCount {
            let box = document.page(at: index)?.bounds(for: .mediaBox) ?? .zero
            XCTAssertLessThanOrEqual(box.height, max(aspectBudget, 0.5) + 0.5)
        }
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            fixture.sentinels, in: Self.text(of: pdf.data)
        )
        XCTAssertNil(controller.webView.window)
    }

    func testExportOverflowStyleDoesNotChangeAnotherController() async throws {
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        let live = PreviewController()
        defer { live.invalidate() }
        live.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        live.setAllowsRemoteImages(false)
        guard case .completed = await live.renderForExport(DocumentTextChange(
            text: source, version: 1, fileKind: .markdown, fileURL: nil
        )) else { return XCTFail("Live render failed") }
        let (exportController, _) = try await capture(source)
        defer { exportController.invalidate() }
        let liveOverflow = try await live.webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('table')).overflow"
        ) as? String
        let exportStyle = try await exportController.webView.evaluateJavaScript(
            "Boolean(document.getElementById('plainsong-export-layout'))"
        ) as? Bool
        XCTAssertEqual(liveOverflow, "auto")
        XCTAssertEqual(exportStyle, true)
        XCTAssertNil(live.webView.window)
    }

    func testCaptureErrorAndMidCaptureCancelPropagateTyped() async throws {
        let controller = try await preparedController("# Hook probe\n")
        defer { controller.invalidate() }
        struct Injected: Error {}
        controller.exportPDFCaptureWillCaptureHook = { _ in throw Injected() }
        do {
            _ = try await controller.captureExportPDF()
            XCTFail("Expected the injected error")
        } catch is Injected {}
        controller.exportPDFCaptureWillCaptureHook = { index in
            if index == 0 { throw CancellationError() }
        }
        do {
            _ = try await controller.captureExportPDF()
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    private func capture(_ markdown: String) async throws -> (PreviewController, ExportPDFDocument) {
        let controller = try await preparedController(markdown)
        let pdf = try await controller.captureExportPDF()
        XCTAssertEqual(pdf.droppedTrailingBlankPages, 0)
        return (controller, pdf)
    }

    private func preparedController(_ markdown: String) async throws -> PreviewController {
        let (controller, ready) = try await prepared(markdown)
        guard case .ready = ready else {
            controller.invalidate()
            throw ExportPDFCaptureError.captureFailed("barrier")
        }
        return controller
    }

    private func prepared(
        _ markdown: String
    ) async throws -> (PreviewController, PreviewHTMLExportResult) {
        let controller = try await PreviewController.makeHTMLExportController()
        controller.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        controller.setAllowsRemoteImages(false)
        controller.setTheme("light")
        let render = await controller.renderForExport(DocumentTextChange(
            text: markdown, version: 1, fileKind: .markdown, fileURL: nil
        ))
        guard case let .completed(renderID) = render else {
            controller.invalidate()
            throw ExportPDFCaptureError.captureFailed("render")
        }
        return await (controller, controller.exportHTML(matchingRenderID: renderID))
    }

    private static func text(of data: Data) -> String {
        guard let document = PDFDocument(data: data) else { return "" }
        return (0 ..< document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }

    private static func assertPagesFit(_ pdf: ExportPDFDocument, file: StaticString = #filePath, line: UInt = #line) {
        guard let document = PDFDocument(data: pdf.data) else {
            return XCTFail("PDF data is empty", file: file, line: line)
        }
        XCTAssertEqual(document.pageCount, pdf.pageCount, file: file, line: line)
        for index in 0 ..< document.pageCount {
            let box = document.page(at: index)?.bounds(for: .mediaBox) ?? .zero
            XCTAssertLessThanOrEqual(box.width, 14400.5, file: file, line: line)
            XCTAssertLessThanOrEqual(box.height, 14400.5, file: file, line: line)
            XCTAssertLessThanOrEqual(box.height, pdf.maximumPageHeight + 0.5, file: file, line: line)
            XCTAssertGreaterThan(box.width, 0, file: file, line: line)
            XCTAssertGreaterThan(box.height, 0, file: file, line: line)
        }
    }

    /// Header, delimiter and one body row. Built from typed pieces: a single long `+` chain
    /// with closures exceeds the hosted CI compiler's type-check time limit.
    private static func tableSource(_ columns: [String], cell: String) -> String {
        let delimiter = [String](repeating: "---", count: columns.count)
        let body = [String](repeating: cell, count: columns.count)
        return [columns, delimiter, body].map(tableRow).joined()
    }

    private static func tableRow(_ cells: [String]) -> String {
        "| " + cells.joined(separator: " | ") + " |\n"
    }
}
