import CoreGraphics
@testable import PreviewKit
import XCTest

final class ExportPDFPagePlannerTailTests: XCTestCase {
    private typealias Span = ExportPDFPagePlanner.Span
    private typealias Extent = ExportPDFPagePlanner.WidthExtent

    func testPaintedTailFitsAndBacksOffToTheLastInterval() throws {
        let short = Span(minY: 0, maxY: 100)
        let fit = try makePlan(
            width: 800, height: 200, spans: [short], paintedBottom: 110,
            bottomInset: 90
        )
        XCTAssertEqual(fit.pages.last?.rect.maxY ?? -1, 110, accuracy: 0.5)
        XCTAssertEqual(fit.droppedTrailingBlankPages, 0)
        ExportPDFPagePlannerTests.assertPlanInvariants(
            fit, contentSize: CGSize(width: 800, height: 200),
            baselineWidth: 800, unsplittable: [short], paintedBottom: 110
        )

        let rows = ExportPDFPagePlannerTests.lineSpans(to: 2400, step: 30, height: 28)
        let last = Span(minY: 2400, maxY: 2500)
        var spans = rows
        spans.append(last)
        let backedOff = try makePlan(
            width: 800, height: 2800, spans: spans, aspect: 1.29,
            paintedBottom: 2700, bottomInset: 100
        )
        XCTAssertEqual(backedOff.pages.last?.rect.maxY ?? -1, 2700, accuracy: 0.5)
        XCTAssertEqual(backedOff.droppedTrailingBlankPages, 0)
        ExportPDFPagePlannerTests.assertPlanInvariants(
            backedOff, contentSize: CGSize(width: 800, height: 4000),
            baselineWidth: 800, unsplittable: spans, aspect: 1.29,
            paintedBottom: 2700
        )
    }

    func testPaintedTailUsesASliverAfterBackoffCannotHoldIt() throws {
        let width: CGFloat = 50000
        let hard = ExportPDFPagePlanner.captureAreaBudget
            / (width + ExportPDFPagePlanner.widePageSlack)
        let span = Span(minY: 0, maxY: 100)
        let end = span.maxY + hard - 10
        let plan = try makePlan(
            width: width, height: end + 100, spans: [span],
            extents: [Extent(minY: span.minY, maxY: span.maxY, maxX: width)],
            paintedBottom: end, bottomInset: 100
        )
        let tailPages = plan.pages.filter { $0.rect.minY >= span.maxY - 0.5 }
        XCTAssertEqual(tailPages.count, 1)
        XCTAssertEqual(tailPages[0].rect.maxY, end, accuracy: 0.5)
        XCTAssertEqual(plan.droppedTrailingBlankPages, 0)
        ExportPDFPagePlannerTests.assertPlanInvariants(
            plan, contentSize: CGSize(width: width, height: end + 100),
            baselineWidth: 800, unsplittable: [span], paintedBottom: end
        )
    }

    private func makePlan(
        width: CGFloat,
        height: CGFloat,
        spans: [Span],
        extents: [Extent] = [],
        aspect: CGFloat? = nil,
        paintedBottom: CGFloat? = nil,
        bottomInset: CGFloat = 0
    ) throws -> ExportPDFPagePlanner.Plan {
        try ExportPDFPagePlanner.plan(
            contentSize: CGSize(width: width, height: height),
            baselineWidth: 800, unsplittable: spans,
            widthExtents: extents, targetAspect: aspect,
            paintedBottom: paintedBottom, bottomInset: bottomInset
        )
    }
}
