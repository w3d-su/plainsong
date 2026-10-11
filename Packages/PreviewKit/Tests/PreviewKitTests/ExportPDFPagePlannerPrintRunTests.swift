import CoreGraphics
@testable import PreviewKit
import XCTest

/// Print-side E1 coverage for the planner (`docs/export-gates.md` D4, owner decision
/// 2026-10-09): inside a wide run the greedy width growth, the `width × aspect` soft
/// budget and the soft extension still apply, in portrait and landscape. Also covers
/// the B2 trailing-page safety net and the randomized invariant/termination guard.
final class ExportPDFPagePlannerPrintRunTests: XCTestCase {
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

    /// Print inside a run keeps the greedy width growth: a page first grows to the
    /// widest extent it spans, then uses that capture width's `width × aspect` soft
    /// budget.
    func testPrintGreedySoftBudgetInsideARun() throws {
        // Touching 100 pt rows give a safe break every 100 pt; the leading block
        // keeps the absorbed run edges at [2000, 4000].
        var spans = [Span(minY: 0, maxY: 2000)]
        for index in 0 ..< 40 {
            let top = CGFloat(2000 + index * 100)
            spans.append(Span(minY: top, maxY: top + 100))
        }
        let extents = [
            Extent(minY: 2000, maxY: 2500, maxX: 2000),
            Extent(minY: 2500, maxY: 4000, maxX: 2400),
        ]
        let plan = try planDocument(
            width: 2400, height: 6000, unsplittable: spans, extents: extents, aspect: 0.5
        )
        assertRunIsolation(plan, runs: [(2000, 4000)])
        // Width grows to the 2,400 capture (no slack under `maximumSide`); the
        // run's pages then end at that width's own soft budget, never past the run.
        let soft: CGFloat = 2400 * 0.5
        let runPages = plan.pages.filter {
            $0.rect.minY >= 2000 - 0.5 && $0.rect.maxY <= 4000 + 0.5
        }
        XCTAssertFalse(runPages.isEmpty)
        for page in runPages {
            XCTAssertEqual(page.rect.width, 2400)
            XCTAssertLessThanOrEqual(page.rect.height, soft + 0.5)
            XCTAssertLessThanOrEqual(page.rect.maxY, 4000 + 0.5)
        }
        XCTAssertEqual(runPages.first?.rect.minY ?? 0, 2000, accuracy: 0.5)
    }

    /// The box extends to its end; the next page owns the trailing gap.
    func testPrintSoftExtensionInsideARun() throws {
        let spans = [
            Span(minY: 0, maxY: 1000),
            Span(minY: 1200, maxY: 2600),
            Span(minY: 3000, maxY: 5000),
        ]
        let extent = Extent(minY: 1000, maxY: 3000, maxX: 2400)
        let plan = try planDocument(
            width: 2400, height: 5000, unsplittable: spans, extents: [extent], aspect: 0.5
        )
        assertRunIsolation(plan, runs: [(1000, 3000)])
        let extended = plan.pages.first { page in
            page.rect.height > 2400 * 0.5 + 0.5
        }
        let rect = try XCTUnwrap(extended?.rect, "The atomic box's page must soft-extend")
        XCTAssertEqual(rect.minY, 1000, accuracy: 0.5)
        XCTAssertEqual(rect.maxY, 2600, accuracy: 0.5)
        XCTAssertEqual(extended?.rect.width, 2400)
    }

    /// Landscape paper inside a run: the wide pages stay bounded by `width × aspect`
    /// (< 1) and come out wider than tall.
    func testPrintRunPagesInLandscape() throws {
        var spans: [Span] = []
        for index in 0 ..< 100 {
            let top = CGFloat(1000 + index * 30)
            spans.append(Span(minY: top, maxY: top + 30))
        }
        let extent = Extent(minY: 1000, maxY: 2500, maxX: 2000)
        let aspect: CGFloat = 0.7
        let plan = try planDocument(
            width: 2400, height: 5000, unsplittable: spans, extents: [extent], aspect: aspect
        )
        // The run absorbs to the document top and the span edge at 2,500.
        assertRunIsolation(plan, runs: [(0, 2500)])
        let runPages = plan.pages.filter { $0.rect.width > 800 }
        XCTAssertGreaterThan(runPages.count, 1)
        for page in runPages {
            XCTAssertLessThanOrEqual(page.rect.height, page.rect.width * aspect + 0.5)
            XCTAssertEqual(page.rect.width, 2000)
        }
    }

    /// A tail with no spans after the last content produces no trailing blank page:
    /// every fully span-free page at the end is dropped (the content-measured B2
    /// height makes this a safety net only), and `droppedTrailingBlankPages`
    /// reports how many.
    func testTrailingSpanFreeTailIsDropped() throws {
        let spans = [Span(minY: 0, maxY: 100), Span(minY: 120, maxY: 220)]
        let plan = try planDocument(width: 800, height: 50000, unsplittable: spans)
        XCTAssertEqual(plan.pages.count, 1)
        XCTAssertEqual(plan.pages[0].rect.maxY, 14400, accuracy: 0.5)
        XCTAssertEqual(plan.droppedTrailingBlankPages, 3)
    }

    /// The drop never removes a page that still holds content: a span reaching into
    /// the last page keeps it even though most of that page is empty space.
    func testTrailingPageWithContentIsKept() throws {
        let spans = [Span(minY: 14000, maxY: 14400), Span(minY: 14400, maxY: 14450)]
        let plan = try planDocument(width: 800, height: 20000, unsplittable: spans)
        XCTAssertEqual(plan.pages.count, 2)
        XCTAssertEqual(plan.pages[1].rect.minY, 14400, accuracy: 0.5)
        XCTAssertEqual(plan.pages[1].rect.maxY, 20000, accuracy: 0.5)
    }

    /// Randomized span/extent sets keep every invariant: contiguity from zero, no
    /// empty pages (every page intersects a measured span), the flat height cap, run
    /// isolation, safe breaks, and a bounded page count that proves the loops
    /// terminate. Precondition for the no-empty-page invariant, per the planner doc:
    /// whitespace gaps between consecutive spans stay below the smallest soft
    /// budget — the generator's gaps are at most 19 pt — and every generated extent
    /// carries its own measured span, as a real measurement always does.
    func testRandomizedRunsKeepInvariantsAndTerminate() throws {
        var state: UInt64 = 0x2F6E_6B6A
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        for iteration in 0 ..< 40 {
            var y: CGFloat = 0
            var spans: [Span] = []
            var extents: [Extent] = []
            var cursor: CGFloat = 0
            // Random unsplittable spans: short line boxes and occasional atomic boxes.
            while cursor < 60000, next(100) < 95 {
                let height = CGFloat(next(40) + 10)
                spans.append(Span(minY: cursor, maxY: cursor + height))
                cursor += height + CGFloat(next(20))
            }
            y = cursor + 5000
            // Random extents inside the span region, half of them past the PDF wide
            // threshold, each carrying the span its own content would measure.
            for _ in 0 ..< next(6) where cursor > 200 {
                let top = CGFloat(next(Int(cursor - 100)))
                let height = min(CGFloat(next(3000) + 100), cursor - top)
                let maxX: CGFloat = next(2) == 0
                    ? CGFloat(1000 + next(13000))
                    : CGFloat(15000 + next(80000))
                spans.append(Span(minY: top, maxY: top + height))
                extents.append(Extent(minY: top, maxY: top + height, maxX: maxX))
            }
            let contentWidth = max(900, (extents.map(\.maxX).max() ?? 900) + 50)
            let aspect: CGFloat? = next(2) == 0 ? nil : [0.7, 1.0, 1.29][next(3)]
            do {
                let plan = try ExportPDFPagePlanner.plan(
                    contentSize: CGSize(width: contentWidth, height: y),
                    baselineWidth: 800,
                    unsplittable: spans,
                    widthExtents: extents,
                    targetAspect: aspect
                )
                ExportPDFPagePlannerTests.assertPlanInvariants(
                    plan, contentSize: CGSize(width: contentWidth, height: y),
                    baselineWidth: 800, unsplittable: spans, aspect: aspect
                )
                ExportPDFPagePlannerTests.assertBreaksAreSafe(plan, unsplittable: spans)
                // Termination guard: pages end at a mandatory break, an interval edge,
                // the content end, or a full soft budget — so the page count is
                // bounded by those finitely many positions.
                let minimumBudget = min(
                    ExportPDFPagePlanner.maximumSide, 800 * (aspect ?? 1)
                )
                let bound = spans.count * 2 + extents.count * 2
                    + Int(y / max(minimumBudget, 1)) + 8
                XCTAssertLessThanOrEqual(
                    plan.pages.count, bound, "iteration \(iteration) produced \(plan.pages.count) pages"
                )
            } catch {
                // `plan` throws typed `ExportPDFCaptureError`, so `error` already
                // is one — no conditional cast needed.
                switch error {
                case .oversizeAtomicBox, .oversizeCaptureArea:
                    break
                default:
                    XCTFail("iteration \(iteration): unexpected error \(error)")
                }
            }
        }
    }
}
