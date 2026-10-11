import AppKit
import PDFKit
@testable import Plainsong
@testable import PreviewKit
import XCTest

@MainActor
final class ExportPDFPaintedTailAppTests: XCTestCase {
    private typealias Support = ExportPDFWideRunsAppSupport

    func test683And684LineCodeBlocksEndAtPaintedBottom() async throws {
        let cases: [(lineCount: Int, expectedEnd: CGFloat)] = [
            (683, 14386), (684, 14407),
        ]
        for (lineCount, expectedEnd) in cases {
            let code = (0 ..< lineCount).map { String(format: "ENDLINE%04dSENTINEL", $0) }
                .joined(separator: "\n")
            let source = "```text\n\(code)\n```"
            let controller = try await Support.preparedController(source)
            defer { controller.invalidate() }
            try await controller.webView.evaluateJavaScript("""
            document.querySelectorAll("#preview-root pre, #preview-root pre code")
              .forEach(element => element.style.setProperty("line-height", "21.494px", "important"));
            const pre = document.querySelector("#preview-root pre");
            pre?.style.setProperty("margin-top", "-15px", "important");
            pre?.style.setProperty("border-bottom", "2px solid #111", "important");
            """)
            let pdf = try await controller.captureExportPDF()
            XCTAssertEqual(pdf.droppedTrailingBlankPages, 0)
            XCTAssertEqual(pdf.paintedBottom, expectedEnd, accuracy: 1)
            XCTAssertLessThanOrEqual(pdf.maximumPageHeight, 14400.5)
            XCTAssertGreaterThanOrEqual(pdf.contentSize.height, expectedEnd)
            XCTAssertLessThanOrEqual(pdf.contentSize.height - expectedEnd, 80)
            let document = try XCTUnwrap(PDFDocument(data: pdf.data))
            XCTAssertEqual(document.pageCount, pdf.plannedPageCount)
            Support.assertEveryPageWithinHardBudget(pdf: pdf, document: document)
            Support.assertEveryPageHasInk(in: document)
            if lineCount == 683 {
                XCTAssertLessThanOrEqual(pdf.paintedBottom, 14400)
            } else {
                XCTAssertGreaterThan(pdf.paintedBottom, 14400)
                XCTAssertGreaterThanOrEqual(document.pageCount, 2)
            }
            let last = try XCTUnwrap(document.page(at: document.pageCount - 1))
            XCTAssertTrue(last.string?.contains(String(format: "ENDLINE%04dSENTINEL", lineCount - 1)) == true)
            let plannedHeight = (0 ..< document.pageCount).reduce(CGFloat.zero) { total, index in
                let page = document.page(at: index)
                let scale = pdf.pageScales[index]
                return total + (page?.bounds(for: .mediaBox).height ?? 0) / scale
            }
            XCTAssertEqual(plannedHeight, pdf.paintedBottom, accuracy: 2)
            XCTAssertTrue(
                hasInkWithinBottom(2, of: last),
                "The last page lost its bottom border ink"
            )
        }
    }

    private func hasInkWithinBottom(_ points: CGFloat, of page: PDFPage) -> Bool {
        let bounds = page.bounds(for: .mediaBox)
        let height = max(1, 600 * bounds.height / bounds.width)
        let image = page.thumbnail(of: NSSize(width: 600, height: height), for: .mediaBox)
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data)
        else { return false }
        let bottomRows = max(1, Int(ceil(points * CGFloat(bitmap.pixelsHigh) / bounds.height)))
        return hasInk(
            in: bitmap.pixelsHigh - bottomRows ..< bitmap.pixelsHigh, bitmap: bitmap
        )
    }

    private func hasInk(in rows: Range<Int>, bitmap: NSBitmapImageRep) -> Bool {
        for y in rows {
            for x in 0 ..< bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB)
                else { continue }
                if color.redComponent < 0.96 || color.greenComponent < 0.96
                    || color.blueComponent < 0.96
                {
                    return true
                }
            }
        }
        return false
    }
}
