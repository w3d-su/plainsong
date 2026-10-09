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
        try ExportPDFPagePlanner.plan(
            contentSize: CGSize(width: width, height: height),
            baselineWidth: baselineWidth,
            unsplittable: unsplittable,
            widthExtents: extents,
            targetAspect: aspect
        )
    }

    /// Run isolation: every page is either disjoint from a run's [minY, maxY] or
    /// wholly contained in it — no page crosses a run boundary.
    private func assertRunIsolation(
        _ plan: ExportPDFPagePlanner.Plan,
        runs: [(minY: CGFloat, maxY: CGFloat)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for page in plan.pages {
            for run in runs {
                for boundary in [run.minY, run.maxY] {
                    XCTAssertFalse(
                        page.rect.minY + 0.5 < boundary && boundary < page.rect.maxY - 0.5,
                        "Page \(page.rect) crosses run boundary \(boundary)",
                        file: file, line: line
                    )
                }
            }
        }
    }

    /// The pages not overlapping a run must sit at the baseline width and scale 1:
    /// normal text never shrinks for somebody else's overflow (E1).
    private func assertProsePagesStayAtBaseline(
        _ plan: ExportPDFPagePlanner.Plan,
        runs: [(minY: CGFloat, maxY: CGFloat)],
        baseline: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for page in plan.pages {
            let insideRun = runs.contains { run in
                page.rect.minY + 0.5 < run.maxY && run.minY + 0.5 < page.rect.maxY
            }
            if !insideRun {
                XCTAssertEqual(page.rect.width, baseline, file: file, line: line)
                XCTAssertEqual(page.scale, 1, file: file, line: line)
            }
        }
    }

    /// Prose, a 28,800 pt run, then prose: the run's pages cover exactly the run at
    /// the wide width and scale 0.5; every prose page stays 800 wide at scale 1.
    func testProseRunProseIsolatesTheRunAtBaseline() throws {
        let extent = Extent(minY: 15000, maxY: 20000, maxX: 28800)
        let plan = try planDocument(width: 28800, height: 40000, extents: [extent])
        ExportPDFPagePlannerTests.assertPlanInvariants(
            plan, contentSize: CGSize(width: 28800, height: 40000),
            baselineWidth: 800, unsplittable: []
        )
        assertRunIsolation(plan, runs: [(15000, 20000)])
        assertProsePagesStayAtBaseline(plan, runs: [(15000, 20000)], baseline: 800)
        let runPages = plan.pages.filter { $0.rect.minY >= 15000 - 0.5 && $0.rect.maxY <= 20000 + 0.5 }
        XCTAssertFalse(runPages.isEmpty)
        for page in runPages {
            XCTAssertEqual(page.rect.width, 28800)
            XCTAssertEqual(page.scale, 0.5, accuracy: 0.0001)
        }
        XCTAssertEqual(runPages.map(\.rect.minY).min() ?? 0, 15000, accuracy: 0.5)
        XCTAssertEqual(runPages.map(\.rect.maxY).max() ?? 0, 20000, accuracy: 0.5)
    }

    /// A run whose top lands exactly on a natural page top still isolates: the page
    /// before ends at the run's top and the run's pages begin there.
    func testRunStartingExactlyAtAPageTop() throws {
        let extent = Extent(minY: 14400, maxY: 16000, maxX: 28800)
        let plan = try planDocument(width: 28800, height: 32000, extents: [extent])
        ExportPDFPagePlannerTests.assertPlanInvariants(
            plan, contentSize: CGSize(width: 28800, height: 32000),
            baselineWidth: 800, unsplittable: []
        )
        assertRunIsolation(plan, runs: [(14400, 16000)])
        XCTAssertEqual(plan.pages[0].rect.maxY, 14400, accuracy: 0.5)
        XCTAssertEqual(plan.pages[0].rect.width, 800)
        let runPage = plan.pages[1].rect
        XCTAssertEqual(runPage.minY, 14400, accuracy: 0.5)
        XCTAssertEqual(runPage.maxY, 16000, accuracy: 0.5)
        XCTAssertEqual(plan.pages[1].rect.width, 28800)
    }

    /// Two runs separated by a single safe break stay isolated from each other and
    /// from the prose: neither page crosses either run's edges, and the break
    /// between them is honoured rather than merged away.
    func testTwoRunsSeparatedByASingleSafeBreakStayIsolated() throws {
        let extents = [
            Extent(minY: 15000, maxY: 16000, maxX: 20000),
            Extent(minY: 16040, maxY: 17000, maxX: 30000),
        ]
        let plan = try planDocument(width: 32000, height: 40000, extents: extents)
        let runs: [(minY: CGFloat, maxY: CGFloat)] = [(15000, 16000), (16040, 17000)]
        ExportPDFPagePlannerTests.assertPlanInvariants(
            plan, contentSize: CGSize(width: 32000, height: 40000),
            baselineWidth: 800, unsplittable: []
        )
        assertRunIsolation(plan, runs: runs)
        assertProsePagesStayAtBaseline(plan, runs: runs, baseline: 800)
        let firstRun = plan.pages.filter { $0.rect.minY >= 15000 - 0.5 && $0.rect.maxY <= 16000 + 0.5 }
        let secondRun = plan.pages.filter { $0.rect.minY >= 16040 - 0.5 && $0.rect.maxY <= 17000 + 0.5 }
        XCTAssertEqual(firstRun.map(\.rect.width), [20000])
        XCTAssertEqual(secondRun.map(\.rect.width), [30000])
    }

    /// Wide extents whose vertical spans overlap merge into one run with one pair of
    /// mandatory breaks; the merged run's pages cover the union.
    func testOverlappingRunsMerge() throws {
        let extents = [
            Extent(minY: 15000, maxY: 16000, maxX: 20000),
            Extent(minY: 15900, maxY: 17000, maxX: 30000),
        ]
        let plan = try planDocument(width: 32000, height: 40000, extents: extents)
        assertRunIsolation(plan, runs: [(15000, 17000)])
        let runPages = plan.pages.filter { $0.rect.minY >= 15000 - 0.5 && $0.rect.maxY <= 17000 + 0.5 }
        XCTAssertEqual(runPages.count, 1)
        XCTAssertEqual(runPages[0].rect.minY, 15000, accuracy: 0.5)
        XCTAssertEqual(runPages[0].rect.maxY, 17000, accuracy: 0.5)
        XCTAssertEqual(runPages[0].rect.width, 30000)
    }

    /// A wide extent nested inside an unsplittable interval snaps the run outward to
    /// the interval's edges, so the run's page covers the whole atomic box.
    func testWideExtentInsideAnUnsplittableIntervalSnapsToItsEdges() throws {
        let atomic = Span(minY: 15000, maxY: 17000)
        let extent = Extent(minY: 15200, maxY: 15500, maxX: 28800)
        let plan = try planDocument(
            width: 28800, height: 40000, unsplittable: [atomic], extents: [extent]
        )
        assertRunIsolation(plan, runs: [(15000, 17000)])
        let runPage = plan.pages.first { $0.rect.minY >= 15000 - 0.5 }
        let rect = try XCTUnwrap(runPage?.rect)
        XCTAssertEqual(rect.minY, 15000, accuracy: 0.5)
        XCTAssertEqual(rect.maxY, 17000, accuracy: 0.5)
        XCTAssertEqual(plan.pages.first { $0.rect.minY >= 15000 - 0.5 }?.rect.width, 28800)
    }

    /// PDF threshold, strict `maxX > 14,400`: 14,399 pt widens its page but is not a
    /// run — the page keeps flowing past the extent's bottom.
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
        let extent = Extent(minY: 0, maxY: 400, maxX: 14401)
        let plan = try planDocument(width: 14401, height: 20000, extents: [extent])
        assertRunIsolation(plan, runs: [(0, 400)])
        let first = try XCTUnwrap(plan.pages.first)
        XCTAssertEqual(first.rect.maxY, 400, accuracy: 0.5)
        XCTAssertEqual(first.rect.width, 14401)
        XCTAssertLessThan(first.scale, 1)
        XCTAssertEqual(plan.pages[1].rect.minY, 400, accuracy: 0.5)
        XCTAssertEqual(plan.pages[1].rect.width, 800)
    }

    /// The Print wide threshold is `baseline / printWideFraction` ≈ 889 on an 800
    /// baseline, strict on both sides: 888 widens without isolating, 890 isolates.
    func testPrintWideThresholdBoundaryOnEachSide() throws {
        let extents = [
            Extent(minY: 0, maxY: 400, maxX: 888),
            Extent(minY: 2000, maxY: 2400, maxX: 890),
        ]
        let plan = try planDocument(
            width: 4000, height: 4000, extents: extents, aspect: 1.0
        )
        // 888 < 800/0.9: not a run, but the page still widens to it greedily and
        // then ends at that width's own soft budget (888 × 1.0).
        XCTAssertEqual(plan.pages[0].rect.width, 888)
        XCTAssertEqual(plan.pages[0].rect.maxY, 888, accuracy: 0.5)
        // 890 > 800/0.9: a run — its page is exactly [2000, 2400].
        assertRunIsolation(plan, runs: [(2000, 2400)])
        let runPage = plan.pages.first { $0.rect.minY >= 2000 - 0.5 }
        let rect = try XCTUnwrap(runPage?.rect)
        XCTAssertEqual(rect.minY, 2000, accuracy: 0.5)
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
            XCTAssertEqual(plan.pages[0].rect.width, 808)
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
            assertRunIsolation(plan, runs: [(20000, 30000)])
            assertProsePagesStayAtBaseline(plan, runs: [(20000, 30000)], baseline: 800)
        }
    }

    /// Past ~37,300 pt wide the capture raster — not the 14,400 pt side — binds:
    /// WebContent dies painting a `pdf()` bitmap near 2³⁰ px (measured 2026-10-09,
    /// `docs/perf-log.md`), so the run's pages trade height for width and stay under
    /// `captureAreaBudget / width`.
    func testVeryWideRunTradesHeightForWidthUnderTheCaptureAreaBudget() throws {
        let spans = (0 ..< 600).map { Span(minY: CGFloat($0) * 100, maxY: CGFloat($0) * 100 + 90) }
        let extent = Extent(minY: 20000, maxY: 30000, maxX: 180_000)
        let plan = try planDocument(
            width: 180_000, height: 60000, unsplittable: spans, extents: [extent]
        )
        let budget = ExportPDFPagePlanner.captureAreaBudget / 180_000
        let runPages = plan.pages.filter {
            $0.rect.minY >= 20000 - 0.5 && $0.rect.maxY <= 30000 + 0.5
        }
        XCTAssertGreaterThan(runPages.count, 2)
        for page in runPages {
            XCTAssertEqual(page.rect.width, 180_000)
            XCTAssertLessThanOrEqual(page.rect.height, budget + 0.5)
        }
        assertRunIsolation(plan, runs: [(20000, 30000)])
        assertProsePagesStayAtBaseline(plan, runs: [(20000, 30000)], baseline: 800)
    }

    /// Under the capture-area budget an unbreakable interval can be oversize below
    /// 14,400 pt: at 180,000 pt wide the hard budget is ~2,983 pt, so a 10,000 pt
    /// atomic box inside the run still throws `oversizeAtomicBox` with its CSS height.
    func testWideAtomicBoxOverTheAreaBudgetThrowsOversize() {
        let atomic = Span(minY: 1000, maxY: 11000)
        let extent = Extent(minY: 1100, maxY: 1200, maxX: 180_000)
        XCTAssertThrowsError(
            try planDocument(width: 180_000, height: 40000, unsplittable: [atomic], extents: [extent])
        ) { error in
            guard let captureError = error as? ExportPDFCaptureError,
                  case let .oversizeAtomicBox(heightPoints) = captureError
            else {
                return XCTFail("Expected oversizeAtomicBox, got \(error)")
            }
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
