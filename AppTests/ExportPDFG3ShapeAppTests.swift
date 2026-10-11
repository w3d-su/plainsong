import AppKit
import PDFKit
@testable import Plainsong
@testable import PreviewKit
import XCTest

@MainActor
final class ExportPDFG3ShapeAppTests: XCTestCase {
    private typealias Support = ExportPDFWideRunsAppSupport

    func testReviewerG3ShapesExportWithInkToPDFAndA4Print() async throws {
        for imageHeight in [1850, 1856] {
            let source = try Support.g3TableSource(imageHeight: imageHeight)
            let controller = try await Support.preparedController(source)
            defer { controller.invalidate() }
            try await controller.applyExportOverflowStyle()
            let contentSize = try await controller.settleExportGeometry()
            let measurement = try await controller.measureUnsplittableSpans()
            let box = try XCTUnwrap(measurement.spans.max(by: { $0.height < $1.height }))
            let extent = try XCTUnwrap(measurement.wide
                .filter { $0.minY < box.maxY && $0.maxY > box.minY }
                .max(by: { $0.maxX < $1.maxX }))
            let captureWidth = min(
                max(extent.maxX, measurement.baselineWidth), contentSize.width
            ) + ExportPDFPagePlanner.widePageSlack
            let area = captureWidth * box.height
            print(String(
                format: "G3 fixture image=%d box=%.1fx%.1f area=%.0f",
                imageHeight, captureWidth, box.height, area
            ))
            XCTAssertLessThan(
                area, ExportPDFPagePlanner.captureAreaBudget,
                "G3 box \(captureWidth)×\(box.height) = \(area) px²"
            )

            let pdfCapture: ExportPDFDocument
            do {
                pdfCapture = try await controller.captureExportPDF()
            } catch {
                XCTFail(
                    "G3 PDF refusal for \(captureWidth)×\(box.height) = \(area) px²: \(error)"
                )
                continue
            }
            let pdf = try XCTUnwrap(PDFDocument(data: pdfCapture.data))
            reportPages("PDF \(imageHeight)", capture: pdfCapture, document: pdf)
            assertSuccessfulCapture(pdfCapture, document: pdf)

            let support = ExportHTMLCommandAppTests()
            let fixture = try support.makeFixture(text: source)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let printed = try await printThroughA4Seam(fixture)
            let printController = try await Support.preparedController(source)
            defer { printController.invalidate() }
            let bounds = a4PrintInfo().imageablePageBounds
            let printCapture = try await printController.captureExportPDF(
                pageAspect: bounds.height / bounds.width
            )
            reportPages("A4 \(imageHeight)", capture: printCapture, document: printed)
            assertSuccessfulCapture(printCapture, document: printed)
        }
    }

    private func reportPages(
        _ label: String,
        capture: ExportPDFDocument,
        document: PDFDocument
    ) {
        print(
            "G3 \(label) pages=\(capture.plannedPageCount)/\(document.pageCount) "
                + "painted=\(capture.paintedBottom) content=\(capture.contentSize.height)"
        )
        for index in 0 ..< document.pageCount {
            let page = document.page(at: index)
            let bounds = page?.bounds(for: .mediaBox) ?? .zero
            let textCount = page?.string?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0
            let inkPixels = page.map { Support.inkPixelCount(in: $0) } ?? 0
            let scale = capture.pageScales.indices.contains(index)
                ? capture.pageScales[index]
                : 0
            print(
                "G3 \(label) page=\(index + 1) box=\(bounds.width)x\(bounds.height) "
                    + "scale=\(scale) ink=\(inkPixels) "
                    + "text=\(textCount)"
            )
        }
    }

    private func assertSuccessfulCapture(
        _ capture: ExportPDFDocument,
        document: PDFDocument,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(capture.plannedPageCount, document.pageCount, file: file, line: line)
        XCTAssertEqual(capture.droppedTrailingBlankPages, 0, file: file, line: line)
        Support.assertNoBlankPage(document, file: file, line: line)
        Support.assertEveryPageHasInk(in: document, file: file, line: line)
        Support.assertEveryPageWithinHardBudget(
            pdf: capture, document: document, file: file, line: line
        )
        XCTAssertEqual(capture.pageScales.count, document.pageCount, file: file, line: line)
        for index in 0 ..< document.pageCount {
            let pageHeight = document.page(at: index)?.bounds(for: .mediaBox).height ?? 0
            let captureHeight = pageHeight / capture.pageScales[index]
            XCTAssertGreaterThanOrEqual(
                pageHeight, 1, "Output page \(index + 1) is a sliver", file: file, line: line
            )
            XCTAssertGreaterThanOrEqual(
                captureHeight, 1, "Capture page \(index + 1) is a sliver", file: file, line: line
            )
        }
    }

    private func printThroughA4Seam(
        _ fixture: ExportHTMLCommandAppTests.Fixture
    ) async throws -> PDFDocument {
        fixture.appState.exportHTMLOperations.printInfoProvider = { self.a4PrintInfo() }
        var observed: PDFDocument?
        fixture.appState.exportHTMLOperations.printDocumentObserver = { observed = $0 }
        fixture.appState.exportHTMLOperations.printOperationRunner = { _, _ in true }
        var results: [ExportHTMLOperationResult] = []
        fixture.appState.exportHTMLOperations.didFinishOperation = { _, result in
            results.append(result)
        }
        try await XCTUnwrap(fixture.appState.printCurrentDocument()).value
        XCTAssertEqual(results, [.printed])
        return try XCTUnwrap(observed, "Print operation did not expose its PDF")
    }

    private func a4PrintInfo() -> NSPrintInfo {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.leftMargin = 18
        info.rightMargin = 18
        info.topMargin = 41
        info.bottomMargin = 18
        info.orientation = .portrait
        return info
    }
}
