import AppKit
import MarkdownCore
import PDFKit
@testable import PreviewKit
import XCTest

/// Production Export as PDF… layout: export-only overflow, uniform scale, and fixed-height pages.
@MainActor
final class ExportPDFLayoutAppTests: XCTestCase {
    func testWideTableCodeMathAndMermaidStayInsideTheCapture() async throws {
        let columns = (0 ..< 12).map { String(format: "GCOLUMN%02dSENTINEL", $0) }
        let table = Self.tableSource(columns, cell: "value")
        let code = "```\n" + String(repeating: "W", count: 180) + "CODERIGHTSENTINEL\n```\n"
        let math = "$$\n" + (0 ..< 12).map { "\\text{KATEX\($0)SENTINEL}+" }.joined() + "x\n$$\n"
        let mermaid = "```mermaid\nflowchart LR\n  A[MERMAIDRIGHTSENTINEL] --> B[END]\n```\n"
        let source = [table, code, math, mermaid, "AFTERALLSENTINEL"].joined(separator: "\n")
        let (controller, pdf) = try await capture(source)
        defer { controller.invalidate() }
        XCTAssertEqual(pdf.scale, 1, "This fixture must stay under 14,400 pt so scale stays 1")
        XCTAssertLessThanOrEqual(pdf.contentSize.width, ExportPDFPagePlanner.maximumSide + 0.5)
        let text = Self.text(of: pdf.data)
        for marker in columns + ["CODERIGHTSENTINEL", "AFTERALLSENTINEL"] {
            XCTAssertEqual(text.components(separatedBy: marker).count - 1, 1, marker)
        }
        let order = columns + ["CODERIGHTSENTINEL", "AFTERALLSENTINEL"]
        var search = text.startIndex
        for marker in order {
            guard let range = text.range(of: marker, range: search ..< text.endIndex) else {
                return XCTFail("Missing \(marker)")
            }
            search = range.upperBound
        }
        let edges = try await controller.webView.evaluateJavaScript("""
        (() => {
          const width = Math.max(document.documentElement.scrollWidth, document.body.scrollWidth);
          const box = (selector) => {
            const node = document.querySelector(selector);
            if (!node) return 0;
            const rect = node.getBoundingClientRect();
            return rect.right + window.scrollX;
          };
          return [width, box("table"), box("pre"), box(".plainsong-math-block"), box(".mermaid-rendered")];
        })()
        """)
        let values = try XCTUnwrap(edges as? [Double])
        XCTAssertEqual(values.count, 5)
        for edge in values.dropFirst() where edge > 0 {
            XCTAssertLessThanOrEqual(edge, values[0] + 1)
        }
        XCTAssertGreaterThan(values[1], 800, "The table must extend past the 800 pt export viewport")
        Self.assertPagesFit(pdf)
    }

    func testWideButFittingCaptureIsNotScaled() async throws {
        // A still-wider table lays out past the width that terminates this WebKit process,
        // so the over-maximum factor is pinned in ExportPDFPagePlannerTests. This capture
        // is the hosted proof that a wide, in-range document stays at scale 1.
        let columns = (0 ..< 200).map { String(format: "C%02d", $0) } + ["SCALERIGHTSENTINEL"]
        let source = Self.tableSource(columns, cell: "x")
        let (controller, pdf) = try await capture(source)
        defer { controller.invalidate() }
        XCTAssertEqual(pdf.scale, 1)
        XCTAssertGreaterThan(pdf.contentSize.width, 10000)
        XCTAssertLessThanOrEqual(pdf.contentSize.width, ExportPDFPagePlanner.maximumSide)
        XCTAssertEqual(Self.text(of: pdf.data).components(separatedBy: "SCALERIGHTSENTINEL").count - 1, 1)
        Self.assertPagesFit(pdf)
        XCTAssertNil(controller.webView.window)
    }

    func testProductionTallCaptureKeepsEverySentinelOnceInOrder() async throws {
        let fixture = ExportPDFMechanismSpikeTests.tallFixture
        let (controller, pdf) = try await capture(fixture.markdown)
        defer { controller.invalidate() }
        XCTAssertGreaterThan(pdf.contentSize.height, 14400)
        XCTAssertGreaterThan(pdf.pageCount, 1)
        XCTAssertLessThanOrEqual(pdf.pageHeight, 14400)
        try ExportPDFMechanismSpikeTests.assertEverySentinelAppearsOnceInOrder(
            fixture.sentinels, in: Self.text(of: pdf.data)
        )
        Self.assertPagesFit(pdf)
        XCTAssertNil(controller.webView.window)
    }

    func testPrintOperationStaysUnmountedAndFitsPaperWidth() async throws {
        let (controller, _) = try await prepared("# Print sentinel\n")
        defer { controller.invalidate() }
        let operation = try await controller.makeExportPrintOperation()
        XCTAssertNil(controller.webView.window)
        XCTAssertTrue(operation.showsPrintPanel)
        XCTAssertEqual(operation.printInfo.horizontalPagination, .fit)
        XCTAssertEqual(operation.printInfo.verticalPagination, .automatic)
        XCTAssertTrue(operation.printPanel.options.contains(.showsScaling))
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

    private func capture(_ markdown: String) async throws -> (PreviewController, ExportPDFDocument) {
        let (controller, ready) = try await prepared(markdown)
        guard case .ready = ready else {
            controller.invalidate()
            throw ExportPDFCaptureError.captureFailed("barrier")
        }
        let pdf = try await controller.captureExportPDF()
        return (controller, pdf)
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
            XCTAssertLessThanOrEqual(box.height, pdf.pageHeight + 0.5, file: file, line: line)
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
