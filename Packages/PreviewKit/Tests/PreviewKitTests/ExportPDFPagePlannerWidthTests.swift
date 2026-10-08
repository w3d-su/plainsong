import CoreGraphics
@testable import PreviewKit
import XCTest

/// Per-page width coverage for the planner: a wide element widens only the pages whose
/// vertical span intersects it, each page scales by its own width, and under an aspect
/// a wide page's height budget grows with its own width.
final class ExportPDFPagePlannerWidthTests: XCTestCase {
    private typealias Span = ExportPDFPagePlanner.Span
    private typealias Extent = ExportPDFPagePlanner.WidthExtent

    private func planDocument(
        width: CGFloat,
        height: CGFloat,
        baselineWidth: CGFloat = 800,
        unsplittable: [Span] = [],
        extents: [Extent] = [],
        aspect: CGFloat? = nil
    ) throws -> ExportPDFPagePlanner.Plan {
        try ExportPDFPagePlanner.plan(
            contentSize: CGSize(width: width, height: height),
            baselineWidth: baselineWidth,
            unsplittable: unsplittable,
            widthExtents: extents,
            targetAspect: aspect
        )
    }

    /// A wide extent on one page widens only that page; neighboring pages keep the
    /// baseline width. Under an aspect the wide page's own budget grows with its width:
    /// it ends past `baseline × aspect` but never past `width × aspect` (greedy Print
    /// budgeting).
    func testPerPageWidthGrowsOnlyThePageContainingWideContent() throws {
        let extent = Extent(minY: 1200, maxY: 1600, maxX: 2400)
        let plan = try planDocument(
            width: 3200, height: 3200, extents: [extent], aspect: 0.5
        )
        ExportPDFPagePlannerTests.assertPlanInvariants(
            plan, contentSize: CGSize(width: 3200, height: 3200),
            baselineWidth: 800, unsplittable: [], aspect: 0.5
        )
        XCTAssertEqual(plan.pages.map(\.rect.width), [800, 800, 800, 2400, 800, 800])
        XCTAssertEqual(plan.pages.map(\.scale), [1, 1, 1, 1, 1, 1])
        // The wide page grew to its own soft budget: 2,400 × 0.5 = 1,200.
        XCTAssertEqual(plan.pages[3].rect.minY, 1200, accuracy: 0.5)
        XCTAssertEqual(plan.pages[3].rect.height, 1200, accuracy: 0.5)
        XCTAssertGreaterThan(plan.pages[3].rect.height, 800 * 0.5)
    }

    /// A page whose own width exceeds 14,400 pt scales down in PDF space while the
    /// other pages stay at 100%.
    func testPerPageScaleShrinksOnlyTheWidePage() throws {
        let extent = Extent(minY: 15000, maxY: 16000, maxX: 28800)
        let plan = try planDocument(
            width: 28800, height: 40000, extents: [extent]
        )
        ExportPDFPagePlannerTests.assertPlanInvariants(
            plan, contentSize: CGSize(width: 28800, height: 40000),
            baselineWidth: 800, unsplittable: []
        )
        XCTAssertEqual(plan.pages.map(\.rect.width), [800, 28800])
        XCTAssertEqual(plan.pages[0].scale, 1)
        XCTAssertEqual(plan.pages[1].scale, 0.5, accuracy: 0.0001)
        // The wide page's CSS height budget is 14,400 / 0.5 = 28,800.
        XCTAssertLessThanOrEqual(plan.pages[1].rect.height, 28800 + 0.5)
        XCTAssertEqual(plan.pages[1].rect.maxY, 40000, accuracy: 0.5)
    }

    /// A narrower extent must not shrink a page below the baseline, and an extent wider
    /// than the measured content width clamps to it.
    func testPageWidthIsNeverBelowBaselineAndNeverAboveContentWidth() throws {
        let extents = [
            Extent(minY: 0, maxY: 400, maxX: 5000),
            Extent(minY: 2000, maxY: 2600, maxX: 400),
        ]
        let plan = try planDocument(
            width: 3000, height: 4000, extents: extents, aspect: 0.6
        )
        ExportPDFPagePlannerTests.assertPlanInvariants(
            plan, contentSize: CGSize(width: 3000, height: 4000),
            baselineWidth: 800, unsplittable: [], aspect: 0.6
        )
        XCTAssertEqual(plan.pages[0].rect.width, 3000)
        XCTAssertEqual(plan.pages.dropFirst().map(\.rect.width), [800, 800, 800, 800, 800])
    }

    /// Soft aspect budget: an atomic run taller than `width × aspect` but under the hard
    /// cap extends the page to the run's end instead of failing.
    func testSoftAspectBudgetExtendsAPageToAnAtomicBoxEnd() throws {
        let atomic = Span(minY: 100, maxY: 1700)
        let plan = try planDocument(
            width: 800, height: 1700, unsplittable: [atomic], aspect: 1.29
        )
        XCTAssertEqual(plan.pages.count, 2)
        XCTAssertEqual(plan.pages[0].rect.height, 100, accuracy: 0.5)
        let extended = plan.pages[1].rect
        XCTAssertEqual(extended.minY, 100, accuracy: 0.5)
        XCTAssertEqual(extended.maxY, 1700, accuracy: 0.5)
        XCTAssertGreaterThan(extended.height, 800 * 1.29)
        ExportPDFPagePlannerTests.assertPlanInvariants(
            plan, contentSize: CGSize(width: 800, height: 1700),
            baselineWidth: 800, unsplittable: [atomic], aspect: 1.29
        )
    }

    /// Landscape paper gives a below-1 aspect: every non-extended page is bounded by
    /// its own `width × aspect`, so pages come out wider than tall.
    func testLandscapeAspectKeepsNonExtendedPagesShorterThanWide() throws {
        let aspect: CGFloat = 559.0 / 783.0
        let spans = (0 ..< 200).map { Span(minY: CGFloat($0) * 30, maxY: CGFloat($0) * 30 + 28) }
        let plan = try planDocument(
            width: 783, height: 5000, baselineWidth: 783, unsplittable: spans, aspect: aspect
        )
        ExportPDFPagePlannerTests.assertPlanInvariants(
            plan, contentSize: CGSize(width: 783, height: 5000),
            baselineWidth: 783, unsplittable: spans, aspect: aspect
        )
        ExportPDFPagePlannerTests.assertBreaksAreSafe(plan, unsplittable: spans)
        XCTAssertGreaterThan(plan.pages.count, 1)
        for page in plan.pages {
            XCTAssertLessThanOrEqual(page.rect.height, page.rect.width * aspect + 0.5)
            XCTAssertLessThan(page.rect.height, page.rect.width)
        }
    }

    /// A wide extent overlapping an atomic run both widens the page and participates in
    /// the soft extension.
    func testWideAtomicRunExtendsAndWidensItsPage() throws {
        let atomic = Span(minY: 0, maxY: 1700)
        let extent = Extent(minY: 200, maxY: 1600, maxX: 2000)
        let plan = try planDocument(
            width: 2400, height: 1700, unsplittable: [atomic], extents: [extent], aspect: 0.7
        )
        XCTAssertEqual(plan.pages.count, 1)
        let page = plan.pages[0].rect
        XCTAssertEqual(page.width, 2000)
        XCTAssertEqual(page.height, 1700, accuracy: 0.5)
        XCTAssertGreaterThan(page.height, 2000 * 0.7)
    }
}
