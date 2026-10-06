import CoreGraphics
@testable import PreviewKit
import XCTest

final class ExportPDFPagePlannerTests: XCTestCase {
    func testFixedHeightMissesBlockInteriorsAndStaysWithinThePlatformMaximum() throws {
        let blocks = (0 ..< 5).map { index in
            let origin = CGFloat(index) * 3000
            return ExportPDFPagePlanner.Block(minY: origin + 20, maxY: origin + 400)
        }
        let height = ExportPDFPagePlanner.fixedHeight(
            contentMinY: 0, contentMaxY: 15000, blocks: blocks
        )
        let pageHeight = try XCTUnwrap(height)
        XCTAssertLessThanOrEqual(pageHeight, ExportPDFPagePlanner.maximumSide)
        XCTAssertGreaterThanOrEqual(pageHeight, 6000)
        var boundary: CGFloat = pageHeight
        while boundary < 15000 - 0.5 {
            XCTAssertFalse(blocks.contains { boundary >= $0.minY - 0.5 && boundary <= $0.maxY + 0.5 })
            boundary += pageHeight
        }
    }

    func testUniformScaleShrinksOnlyPastTheMaximum() {
        XCTAssertEqual(ExportPDFPagePlanner.uniformScale(containedWidth: 800), 1)
        XCTAssertEqual(ExportPDFPagePlanner.uniformScale(containedWidth: 14400), 1)
        let shrunk = ExportPDFPagePlanner.uniformScale(containedWidth: 28800)
        XCTAssertEqual(shrunk, 0.5, accuracy: 0.0001)
        XCTAssertEqual(28800 * shrunk, 14400, accuracy: 0.1)
    }

    func testNoCandidateIsReturnedWhenEveryBoundaryCutsABlock() {
        let blocks = [ExportPDFPagePlanner.Block(minY: 0, maxY: 20000)]
        XCTAssertNil(ExportPDFPagePlanner.fixedHeight(contentMinY: 0, contentMaxY: 20000, blocks: blocks))
    }

    func testJoinedPagesKeepEachMediaBox() throws {
        let first = try Self.page(width: 200, height: 100)
        let second = try Self.page(width: 180, height: 90)
        let joined = try ExportPDFPageJoiner.join([first, second])
        guard let document = CGPDFDocument(CGDataProvider(data: joined as CFData)!) else {
            return XCTFail("Joined data is not a PDF")
        }
        XCTAssertEqual(document.numberOfPages, 2)
        XCTAssertEqual(document.page(at: 1)?.getBoxRect(.mediaBox).height ?? 0, 100, accuracy: 0.5)
        XCTAssertEqual(document.page(at: 2)?.getBoxRect(.mediaBox).height ?? 0, 90, accuracy: 0.5)
    }

    private static func page(width: CGFloat, height: CGFloat) throws -> Data {
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
