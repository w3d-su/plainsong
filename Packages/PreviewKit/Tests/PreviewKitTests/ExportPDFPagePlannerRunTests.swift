import CoreGraphics
@testable import PreviewKit
import XCTest

/// E1 wide-run coverage for the planner (`docs/export-gates.md` D4, owner decision
/// 2026-10-09): an extent whose right edge crosses the product's wide threshold —
/// 14,400 pt for PDF, `baseline / 0.9` for Print — is isolated on its own pages,
/// every page is capped at a flat 14,400 CSS pt whatever its width, and run
/// boundaries are mandatory breaks no page crosses.
final class ExportPDFPagePlannerRunTests: XCTestCase {
    private typealias Span = ExportPDFPagePlanner.Span
    private typealias Extent = ExportPDFPagePlanner.WidthExtent
    private typealias Page = ExportPDFPagePlanner.Page

    private func planDocument(
        width: CGFloat,
        height: CGFloat,
        baselineWidth: CGFloat = 800,
        unsplittable: [Span] = [],
        extents: [Extent] = [],
        aspect: CGFloat? = nil
    ) throws -> ExportPDFPagePlanner.Plan {
        try ExportPDFPagePlannerTests.planRunDocument(
            width: width, height: height, baselineWidth: baselineWidth,
            unsplittable: unsplittable, extents: extents, aspect: aspect
        )
    }

    private func assertRunIsolation(
        _ plan: ExportPDFPagePlanner.Plan,
        runs: [(minY: CGFloat, maxY: CGFloat)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        ExportPDFPagePlannerTests.assertRunIsolation(plan, runs: runs, file: file, line: line)
    }

    private func assertProsePagesStayAtBaseline(
        _ plan: ExportPDFPagePlanner.Plan,
        runs: [(minY: CGFloat, maxY: CGFloat)],
        baseline: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        ExportPDFPagePlannerTests.assertProsePagesStayAtBaseline(
            plan, runs: runs, baseline: baseline, file: file, line: line
        )
    }

    /// Prose, a 28,800 pt run, then prose: the run's pages cover exactly the absorbed
    /// run at the wide capture width (content plus `widePageSlack` overscan) and
    /// scale to fit; every prose page stays 800 wide at scale 1.
    func testProseRunProseIsolatesTheRunAtBaseline() throws {
        let spans = ExportPDFPagePlannerTests.lineSpans(to: 40000)
        let extent = Extent(minY: 15000, maxY: 20000, maxX: 28800)
        let plan = try planDocument(
            width: 28800, height: 40000, unsplittable: spans, extents: [extent]
        )
        ExportPDFPagePlannerTests.assertPlanInvariants(
            plan, contentSize: CGSize(width: 28800, height: 40000),
            baselineWidth: 800, unsplittable: spans
        )
        // Gap absorption: the run's top climbs to the last span edge before the
        // extent (14,998); its bottom snaps out of the span holding 20,000 and
        // climbs to the next span's top (20,010).
        let runs: [(minY: CGFloat, maxY: CGFloat)] = [(14998, 20010)]
        assertRunIsolation(plan, runs: runs)
        assertProsePagesStayAtBaseline(plan, runs: runs, baseline: 800)
        let runPages = plan.pages.filter {
            $0.rect.minY >= 14998 - 0.5 && $0.rect.maxY <= 20010 + 0.5
        }
        XCTAssertFalse(runPages.isEmpty)
        for page in runPages {
            XCTAssertEqual(page.rect.width, 28800 + ExportPDFPagePlanner.widePageSlack)
            XCTAssertEqual(
                page.scale,
                ExportPDFPagePlanner.pageScale(
                    width: 28800 + ExportPDFPagePlanner.widePageSlack
                ),
                accuracy: 0.0001
            )
        }
        XCTAssertEqual(runPages.map(\.rect.minY).min() ?? 0, 14998, accuracy: 0.5)
        XCTAssertEqual(runPages.map(\.rect.maxY).max() ?? 0, 20010, accuracy: 0.5)
    }

    /// A run whose top lands exactly on a natural page top still isolates: the page
    /// before ends at the run's top and the run's pages begin there.
    func testRunStartingExactlyAtAPageTop() throws {
        let spans = ExportPDFPagePlannerTests.lineSpans(to: 32000)
        let extent = Extent(minY: 14400, maxY: 16000, maxX: 28800)
        let plan = try planDocument(
            width: 28800, height: 32000, unsplittable: spans, extents: [extent]
        )
        ExportPDFPagePlannerTests.assertPlanInvariants(
            plan, contentSize: CGSize(width: 28800, height: 32000),
            baselineWidth: 800, unsplittable: spans
        )
        // Absorbed edges: the last span ending before 14,400 and the first span
        // starting after the 15,990–16,018 box that holds the extent's bottom.
        assertRunIsolation(plan, runs: [(14398, 16020)])
        XCTAssertEqual(plan.pages[0].rect.maxY, 14398, accuracy: 0.5)
        XCTAssertEqual(plan.pages[0].rect.width, 800)
        let runPage = plan.pages[1].rect
        XCTAssertEqual(runPage.minY, 14398, accuracy: 0.5)
        XCTAssertEqual(runPage.maxY, 16020, accuracy: 0.5)
        XCTAssertEqual(plan.pages[1].rect.width, 28800 + ExportPDFPagePlanner.widePageSlack)
    }

    /// Wide extents whose vertical spans overlap merge into one run with one pair of
    /// mandatory breaks; the merged run's pages cover the union.
    func testOverlappingRunsMerge() throws {
        let spans = ExportPDFPagePlannerTests.lineSpans(to: 40000)
        let extents = [
            Extent(minY: 15000, maxY: 16000, maxX: 20000),
            Extent(minY: 15900, maxY: 17000, maxX: 30000),
        ]
        let plan = try planDocument(
            width: 32000, height: 40000, unsplittable: spans, extents: extents
        )
        // Merged [15000,17000] then absorbed outward to the neighbouring span
        // edges: 14,998 and 17,010.
        assertRunIsolation(plan, runs: [(14998, 17010)])
        let runPages = plan.pages.filter {
            $0.rect.minY >= 14998 - 0.5 && $0.rect.maxY <= 17010 + 0.5
        }
        XCTAssertEqual(runPages.count, 1)
        XCTAssertEqual(runPages[0].rect.minY, 14998, accuracy: 0.5)
        XCTAssertEqual(runPages[0].rect.maxY, 17010, accuracy: 0.5)
        XCTAssertEqual(runPages[0].rect.width, 30000 + ExportPDFPagePlanner.widePageSlack)
    }

    /// A wide extent nested inside an unsplittable interval snaps the run outward to
    /// the interval's edges, so the run's page covers the whole atomic box.
    func testWideExtentInsideAnUnsplittableIntervalSnapsToItsEdges() throws {
        let atomic = Span(minY: 15000, maxY: 17000)
        var spans = ExportPDFPagePlannerTests.lineSpans(to: 15000)
        spans.append(atomic)
        spans.append(contentsOf: ExportPDFPagePlannerTests.lineSpans(from: 17000, to: 40000))
        let extent = Extent(minY: 15200, maxY: 15500, maxX: 28800)
        let plan = try planDocument(
            width: 28800, height: 40000, unsplittable: spans, extents: [extent]
        )
        assertRunIsolation(plan, runs: [(14998, 17000)])
        let runPage = plan.pages.first { $0.rect.minY >= 14998 - 0.5 }
        let rect = try XCTUnwrap(runPage?.rect)
        XCTAssertEqual(rect.minY, 14998, accuracy: 0.5)
        XCTAssertEqual(rect.maxY, 17000, accuracy: 0.5)
        XCTAssertEqual(
            plan.pages.first { $0.rect.minY >= 14998 - 0.5 }?.rect.width,
            28800 + ExportPDFPagePlanner.widePageSlack
        )
    }

    /// PDF threshold, strict `maxX > 14,400`: 14,399 pt widens its page but is not a
    /// run — and being under `maximumSide` it captures exactly, unscaled.
    func testExtentAt14399WidensButIsNotARun() throws {
        let extent = Extent(minY: 0, maxY: 400, maxX: 14399)
        let plan = try planDocument(width: 14399, height: 20000, extents: [extent])
        XCTAssertEqual(plan.pages[0].rect.maxY, 14400, accuracy: 0.5)
        XCTAssertEqual(plan.pages[0].rect.width, 14399)
        XCTAssertEqual(plan.pages[0].scale, 1)
    }

    /// …while 14,401 pt is a PDF wide run: its page is isolated to the extent's span
    /// and scaled past the 200-inch limit.
    func testExtentAt14401IsARun() throws {
        let spans = ExportPDFPagePlannerTests.lineSpans(to: 20000)
        let extent = Extent(minY: 0, maxY: 400, maxX: 14401)
        let plan = try planDocument(
            width: 14401, height: 20000, unsplittable: spans, extents: [extent]
        )
        // The extent's bottom sits inside the [390,418] line box, so the run snaps
        // out and absorbs to the next span's top: [0, 420].
        assertRunIsolation(plan, runs: [(0, 420)])
        let first = try XCTUnwrap(plan.pages.first)
        XCTAssertEqual(first.rect.maxY, 420, accuracy: 0.5)
        XCTAssertEqual(first.rect.width, 14401 + ExportPDFPagePlanner.widePageSlack)
        XCTAssertLessThan(first.scale, 1)
        XCTAssertEqual(plan.pages[1].rect.minY, 420, accuracy: 0.5)
        XCTAssertEqual(plan.pages[1].rect.width, 800)
    }

    /// The Print wide threshold is `baseline / printWideFraction` ≈ 889 on an 800
    /// baseline, strict on both sides: 888 widens without isolating, 890 isolates.
    func testPrintWideThresholdBoundaryOnEachSide() throws {
        let spans = ExportPDFPagePlannerTests.lineSpans(to: 4000)
        let extents = [
            Extent(minY: 0, maxY: 400, maxX: 888),
            Extent(minY: 2000, maxY: 2400, maxX: 890),
        ]
        let plan = try planDocument(
            width: 4000, height: 4000, unsplittable: spans,
            extents: extents, aspect: 1.0
        )
        // 888 < 800/0.9: not a run, but the first page still widens to it greedily
        // and ends at the last safe break inside that width's own soft budget —
        // target 888 lands inside the [870, 898] line box, so the page breaks at
        // 870. 888 ≤ `maximumSide`, so the page gets no `widePageSlack` overscan.
        XCTAssertEqual(plan.pages[0].rect.width, 888)
        XCTAssertEqual(plan.pages[0].rect.maxY, 870, accuracy: 0.5)
        XCTAssertEqual(plan.pages[0].scale, 1)
        // 890 > 800/0.9: a run — absorbed outward to the neighbouring span edges.
        // It is still under `maximumSide`, so it captures at exactly 890 too.
        assertRunIsolation(plan, runs: [(1978, 2400)])
        let runPage = plan.pages.first { $0.rect.minY >= 1978 - 0.5 }
        let rect = try XCTUnwrap(runPage?.rect)
        XCTAssertEqual(rect.minY, 1978, accuracy: 0.5)
        XCTAssertEqual(rect.maxY, 2400, accuracy: 0.5)
        XCTAssertEqual(runPage?.rect.width, 890)
    }

    /// 808 on an 800 baseline — the kitchen-sink fixture's width — is a run in
    /// neither product, so it keeps its current one-page result.
    func test808On800IsNeverARun() throws {
        let extent = Extent(minY: 0, maxY: 400, maxX: 808)
        for aspect: CGFloat? in [nil, 1.29] {
            let plan = try planDocument(
                width: 900, height: 1000, extents: [extent], aspect: aspect
            )
            XCTAssertEqual(plan.pages.count, 1)
            XCTAssertEqual(
                plan.pages[0].rect.width, 808
            )
            XCTAssertEqual(plan.pages[0].scale, 1)
        }
    }

    /// Whatever the width — 20,000, 114,000 or 1,137,726 pt — every page's CSS height
    /// stays under the flat 14,400 cap, so WebKit never sees a taller capture.
    func testWideRunPagesStayUnderTheMaximumForAnyWidth() throws {
        let spans = (0 ..< 600).map { Span(minY: CGFloat($0) * 100, maxY: CGFloat($0) * 100 + 90) }
        for width: CGFloat in [20000, 114_000, 1_137_726] {
            let extent = Extent(minY: 20000, maxY: 30000, maxX: width)
            let plan = try planDocument(
                width: width, height: 60000, unsplittable: spans, extents: [extent]
            )
            for page in plan.pages {
                XCTAssertLessThanOrEqual(
                    page.rect.height, ExportPDFPagePlanner.maximumSide + 0.5,
                    "width \(width): page \(page.rect) taller than the cap"
                )
            }
            // Absorbed edges: the last row ending before 20,000 and the row edge
            // at 30,000 itself.
            let runs: [(minY: CGFloat, maxY: CGFloat)] = [(19990, 30000)]
            assertRunIsolation(plan, runs: runs)
            assertProsePagesStayAtBaseline(plan, runs: runs, baseline: 800)
        }
    }

    /// Past ~37,300 pt wide the capture raster — not the 14,400 pt side — binds:
    /// WebContent dies painting a `pdf()` bitmap near 2³⁰ px (measured 2026-10-09,
    /// `docs/perf-log.md`), so the run's pages trade height for width and stay under
    /// `captureAreaBudget / capture width` — the slack counts toward the area.
    func testVeryWideRunTradesHeightForWidthUnderTheCaptureAreaBudget() throws {
        let spans = (0 ..< 600).map { Span(minY: CGFloat($0) * 100, maxY: CGFloat($0) * 100 + 90) }
        let extent = Extent(minY: 20000, maxY: 30000, maxX: 180_000)
        let plan = try planDocument(
            width: 180_000, height: 60000, unsplittable: spans, extents: [extent]
        )
        let captureWidth = 180_000 + ExportPDFPagePlanner.widePageSlack
        let budget = ExportPDFPagePlanner.captureAreaBudget / captureWidth
        let runPages = plan.pages.filter {
            $0.rect.minY >= 19990 - 0.5 && $0.rect.maxY <= 30000 + 0.5
        }
        XCTAssertGreaterThan(runPages.count, 2)
        for page in runPages {
            XCTAssertEqual(page.rect.width, captureWidth)
            XCTAssertLessThanOrEqual(page.rect.height, budget + 0.5)
        }
        assertRunIsolation(plan, runs: [(19990, 30000)])
        assertProsePagesStayAtBaseline(plan, runs: [(19990, 30000)], baseline: 800)
    }

    /// Under the capture-area budget a *single unbreakable* interval is oversize below
    /// 14,400 pt: at ~180,200 pt capture width the hard budget is ~2,978 pt, so a
    /// 10,000 pt atomic box inside the run throws `oversizeCaptureArea` reporting its
    /// own CSS width and height — a wide run that could be split never throws (G3).
    func testWideAtomicBoxOverTheAreaBudgetThrowsOversizeCaptureArea() {
        let atomic = Span(minY: 1000, maxY: 11000)
        let extent = Extent(minY: 1100, maxY: 1200, maxX: 180_000)
        XCTAssertThrowsError(
            try planDocument(width: 180_000, height: 40000, unsplittable: [atomic], extents: [extent])
        ) { error in
            guard let captureError = error as? ExportPDFCaptureError,
                  case let .oversizeCaptureArea(widthPoints, heightPoints) = captureError
            else {
                return XCTFail("Expected oversizeCaptureArea, got \(error)")
            }
            XCTAssertEqual(widthPoints, 180_000, accuracy: 0.5)
            XCTAssertEqual(heightPoints, 10000, accuracy: 0.5)
        }
    }

    /// An unbreakable interval taller than 14,400 CSS pt inside a wide run still
    /// fails typed; the reported height is the interval's CSS height.
    func testAtomicBoxTallerThanTheCapInsideARunThrowsOversize() {
        let atomic = Span(minY: 1000, maxY: 16000)
        let extent = Extent(minY: 1100, maxY: 1200, maxX: 28800)
        XCTAssertThrowsError(
            try planDocument(width: 28800, height: 40000, unsplittable: [atomic], extents: [extent])
        ) { error in
            guard let captureError = error as? ExportPDFCaptureError,
                  case let .oversizeAtomicBox(heightPoints) = captureError
            else {
                return XCTFail("Expected oversizeAtomicBox, got \(error)")
            }
            XCTAssertEqual(heightPoints, 15000, accuracy: 0.5)
        }
    }
}
