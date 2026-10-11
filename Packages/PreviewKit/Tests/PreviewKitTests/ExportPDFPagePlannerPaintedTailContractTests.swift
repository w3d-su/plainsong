import CoreGraphics
@testable import PreviewKit
import XCTest

final class ExportPDFPaintedTailTests: XCTestCase {
    func testPaintedCodeEndsAt683And684LineMeasurementsAndReportsStaleHeight() throws {
        for end in [14384.0, 14405.0] {
            let spans = ExportPDFPagePlannerTests.lineSpans(
                from: 41, to: end, step: 21, height: 21
            )
            let plan = try ExportPDFPagePlanner.plan(
                contentSize: CGSize(width: 800, height: end + 48),
                baselineWidth: 800,
                unsplittable: spans,
                widthExtents: [],
                paintedBottom: end,
                bottomInset: 48
            )
            XCTAssertEqual(plan.pages.last?.rect.maxY ?? -1, end, accuracy: 0.5)
            XCTAssertEqual(plan.droppedTrailingBlankPages, 0)
        }
        let stale = try ExportPDFPagePlanner.plan(
            contentSize: CGSize(width: 800, height: 50000),
            baselineWidth: 800,
            unsplittable: [ExportPDFPagePlanner.Span(minY: 0, maxY: 1000)],
            widthExtents: [],
            paintedBottom: 1000,
            bottomInset: 10
        )
        XCTAssertGreaterThan(stale.droppedTrailingBlankPages, 0)
    }
}
