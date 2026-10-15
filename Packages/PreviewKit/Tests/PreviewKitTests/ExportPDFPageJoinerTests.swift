import CoreGraphics
@testable import PreviewKit
import XCTest

/// `ExportPDFPageJoiner` coverage: per-piece media boxes and per-page PDF-space scales.
/// Split out of `ExportPDFPagePlannerTests` to keep each file inside the ~400-line
/// budget.
final class ExportPDFPageJoinerTests: XCTestCase {
    func testJoinedPagesKeepEachMediaBox() throws {
        let first = try Self.page(width: 200, height: 100)
        let second = try Self.page(width: 180, height: 90)
        let joined = try ExportPDFPageJoiner.join([first, second], scales: [1, 1])
        XCTAssertEqual(joined.pageScales, [1, 1])
        guard let document = CGPDFDocument(CGDataProvider(data: joined.data as CFData)!) else {
            return XCTFail("Joined data is not a PDF")
        }
        XCTAssertEqual(document.numberOfPages, 2)
        XCTAssertEqual(document.page(at: 1)?.getBoxRect(.mediaBox).height ?? 0, 100, accuracy: 0.5)
        XCTAssertEqual(document.page(at: 2)?.getBoxRect(.mediaBox).height ?? 0, 90, accuracy: 0.5)
    }

    func testJoinerScaleShrinksTheMediaBox() throws {
        let page = try Self.page(width: 200, height: 100)
        let joined = try ExportPDFPageJoiner.join([page], scales: [0.5])
        XCTAssertEqual(joined.pageScales, [0.5])
        guard let document = CGPDFDocument(CGDataProvider(data: joined.data as CFData)!) else {
            return XCTFail("Joined data is not a PDF")
        }
        let box = try XCTUnwrap(document.page(at: 1)?.getBoxRect(.mediaBox))
        XCTAssertEqual(box.width, 100, accuracy: 0.5)
        XCTAssertEqual(box.height, 50, accuracy: 0.5)
    }

    /// Per-piece scales are per page, so only the wide piece's media box shrinks.
    func testJoinerAppliesEachPiecesScaleToItsPages() throws {
        let first = try Self.page(width: 200, height: 100)
        let second = try Self.page(width: 240, height: 120)
        let joined = try ExportPDFPageJoiner.join([first, second], scales: [1, 0.5])
        XCTAssertEqual(joined.pageScales, [1, 0.5])
        guard let document = CGPDFDocument(CGDataProvider(data: joined.data as CFData)!) else {
            return XCTFail("Joined data is not a PDF")
        }
        let firstBox = try XCTUnwrap(document.page(at: 1)?.getBoxRect(.mediaBox))
        let secondBox = try XCTUnwrap(document.page(at: 2)?.getBoxRect(.mediaBox))
        XCTAssertEqual(firstBox.width, 200, accuracy: 0.5)
        XCTAssertEqual(secondBox.width, 120, accuracy: 0.5)
    }

    func testJoinerRequiresAScalePerPiece() throws {
        let page = try Self.page(width: 100, height: 50)
        XCTAssertThrowsError(try ExportPDFPageJoiner.join([page], scales: [1, 1])) { error in
            guard let captureError = error as? ExportPDFCaptureError,
                  case .captureFailed = captureError
            else {
                return XCTFail("Expected captureFailed, got \(error)")
            }
        }
    }

    static func page(width: CGFloat, height: CGFloat) throws -> Data {
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let consumer = try XCTUnwrap(CGDataConsumer(data: output))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }
}
