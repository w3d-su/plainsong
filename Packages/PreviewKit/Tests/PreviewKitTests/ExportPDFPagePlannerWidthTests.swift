import CoreGraphics
@testable import PreviewKit
import XCTest

/// Per-page width coverage for the planner: a wide element widens only the pages whose
/// vertical span intersects it, each page scales by its own width, and under an aspect
/// a wide page's height budget grows with its own width. Extents past the product's
/// wide threshold form isolated runs; those live in `ExportPDFPagePlannerRunTests`.
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

    /// A wide extent forms a Print run (2,400 > 800/0.9), so its pages are isolated:
    /// the neighbouring prose pages keep the baseline width and the run's own page is
    /// bounded by the absorbed run's edges, not by its soft `width × aspect` budget.
    func testPerPageWidthGrowsOnlyThePageContainingWideContent() throws {
        let spans = ExportPDFPagePlannerTests.lineSpans(to: 3200)
        let extent = Extent(minY: 1200, maxY: 1600, maxX: 2400)
        let plan = try planDocument(
            width: 3200, height: 3200, unsplittable: spans,
            extents: [extent], aspect: 0.5
        )
        ExportPDFPagePlannerTests.assertPlanInvariants(
            plan, contentSize: CGSize(width: 3200, height: 3200),
            baselineWidth: 800, unsplittable: spans, aspect: 0.5
        )
        let wideWidth: CGFloat = 2400
        XCTAssertTrue(plan.pages.allSatisfy {
            $0.rect.width == 800 || $0.rect.width == wideWidth
        })
        XCTAssertTrue(plan.pages.allSatisfy { $0.scale == 1 })
        // The run starts at the extent edge (1200, already a line-box boundary) and
        // snaps its bottom outward to the interval edge at 1620. Its measured width
        // (2,400) is under `maximumSide`, so no slack applies.
        let runPage = try XCTUnwrap(plan.pages.first { $0.rect.width > 800 })
        XCTAssertEqual(runPage.rect.minY, 1200, accuracy: 0.5)
        XCTAssertEqual(runPage.rect.maxY, 1620, accuracy: 0.5)
        XCTAssertLessThan(runPage.rect.height, wideWidth * 0.5)
    }

    /// A page whose own width exceeds 14,400 pt scales down in PDF space while the
    /// other pages stay at 100%. The extent is a PDF wide run, so its page is isolated
    /// to the run's span and capped at 14,400 CSS pt like every other page.
    func testPerPageScaleShrinksOnlyTheWidePage() throws {
        let spans = ExportPDFPagePlannerTests.lineSpans(to: 40000)
        let extent = Extent(minY: 15000, maxY: 16000, maxX: 28800)
        let plan = try planDocument(
            width: 28800, height: 40000, unsplittable: spans, extents: [extent]
        )
        ExportPDFPagePlannerTests.assertPlanInvariants(
            plan, contentSize: CGSize(width: 28800, height: 40000),
            baselineWidth: 800, unsplittable: spans
        )
        let wideWidth = 28800 + ExportPDFPagePlanner.widePageSlack
        XCTAssertEqual(
            plan.pages.map(\.rect.width), [800, 800, wideWidth, 800, 800]
        )
        let runPage = plan.pages[2]
        XCTAssertEqual(runPage.rect.minY, 15000, accuracy: 0.5)
        XCTAssertEqual(runPage.rect.maxY, 16020, accuracy: 0.5)
        XCTAssertEqual(
            runPage.scale,
            ExportPDFPagePlanner.pageScale(width: wideWidth),
            accuracy: 0.0001
        )
        for (index, page) in plan.pages.enumerated() where index != 2 {
            XCTAssertEqual(page.scale, 1)
            XCTAssertLessThanOrEqual(page.rect.height, 14400 + 0.5)
        }
    }

    /// A narrower extent must not shrink a page below the baseline, and an extent wider
    /// than the measured content width clamps to it — at 3,000 pt (< `maximumSide`)
    /// the page captures exactly its clamped width, no `widePageSlack` overscan.
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
        let first = try XCTUnwrap(plan.pages.first)
        XCTAssertEqual(first.rect.width, 3000)
        XCTAssertTrue(plan.pages.dropFirst().allSatisfy { $0.rect.width == 800 })
    }

    /// Soft aspect budget: an atomic box taller than `width × aspect` but under the
    /// hard cap extends its page to the box's end — and because the slice before the
    /// box holds no span, the page grows over the whitespace instead of emitting it
    /// as a blank page (X1).
    func testSoftAspectBudgetExtendsAPageToAnAtomicBoxEnd() throws {
        let atomic = Span(minY: 100, maxY: 1700)
        let plan = try planDocument(
            width: 800, height: 1700, unsplittable: [atomic], aspect: 1.29
        )
        XCTAssertEqual(plan.pages.count, 1)
        let extended = plan.pages[0].rect
        XCTAssertEqual(extended.minY, 0, accuracy: 0.5)
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

    /// `widePageSlack` overscan applies only past `maximumSide` (Y2, corrected
    /// 2026-10-10): a Print page at 880 — under the 888 run threshold — and a PDF
    /// page at 14,000 both fit, so slack would only lower their scale, and a
    /// 200,000 pt run page captures exactly +200.
    func testCaptureSlackAppliesOnlyPastTheMaximumSide() throws {
        let spans = ExportPDFPagePlannerTests.lineSpans(to: 2000)
        // Print non-run: 880 < 800/0.9 ≈ 889, and ≤ 14,400 — capture is exact.
        let printPage = try planDocument(
            width: 2000, height: 2000, unsplittable: spans,
            extents: [Extent(minY: 0, maxY: 400, maxX: 880)], aspect: 1.29
        )
        XCTAssertEqual(printPage.pages[0].rect.width, 880)
        // PDF non-run: 14,000 < `maximumSide` — capture is exact too.
        let pdfPage = try planDocument(
            width: 20000, height: 2000, unsplittable: spans,
            extents: [Extent(minY: 0, maxY: 400, maxX: 14000)]
        )
        XCTAssertEqual(pdfPage.pages[0].rect.width, 14000)
        // Run page past `maximumSide`: exactly `width + widePageSlack`.
        let runPlan = try planDocument(
            width: 200_000, height: 2000, unsplittable: spans,
            extents: [Extent(minY: 0, maxY: 400, maxX: 200_000)]
        )
        XCTAssertEqual(
            runPlan.pages[0].rect.width,
            200_000 + ExportPDFPagePlanner.widePageSlack
        )
    }
}
