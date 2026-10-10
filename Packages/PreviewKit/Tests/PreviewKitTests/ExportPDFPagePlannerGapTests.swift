import CoreGraphics
@testable import PreviewKit
import XCTest

/// X1 gap-absorption coverage for the planner (`docs/export-gates.md` D4, owner
/// decision 2026-10-10): a wide run's snapped edges grow across the neighbouring
/// span-free gaps so a mandatory break never strands whitespace on its own page,
/// and runs separated only by a shared safe break stay separate.
final class ExportPDFPagePlannerGapTests: XCTestCase {
    private typealias Span = ExportPDFPagePlanner.Span
    private typealias Extent = ExportPDFPagePlanner.WidthExtent

    /// Two runs separated only by a shared safe break — touching intervals, no gap —
    /// stay isolated from each other and from the prose: neither page crosses either
    /// run's edges, the shared edge collapses to one boundary, and no empty page can
    /// form between them (X1).
    func testTwoRunsSeparatedByASingleSafeBreakStayIsolated() throws {
        let atomic1 = Span(minY: 15000, maxY: 16000)
        let atomic2 = Span(minY: 16000, maxY: 17000)
        var spans = ExportPDFPagePlannerTests.lineSpans(to: 15000)
        spans.append(atomic1)
        spans.append(atomic2)
        spans.append(contentsOf: ExportPDFPagePlannerTests.lineSpans(from: 17000, to: 40000))
        let extents = [
            Extent(minY: 15100, maxY: 15900, maxX: 20000),
            Extent(minY: 16100, maxY: 16900, maxX: 30000),
        ]
        let plan = try ExportPDFPagePlannerTests.planRunDocument(
            width: 32000, height: 40000, unsplittable: spans, extents: extents
        )
        // Each run snaps to its interval's edges; the first absorbs the 2 pt margin
        // to the last line span, and the two share the 16,000 edge — pinned to one
        // boundary, not merged and not separated by a hairline page.
        let runs: [(minY: CGFloat, maxY: CGFloat)] = [(14998, 16000), (16000, 17000)]
        ExportPDFPagePlannerTests.assertPlanInvariants(
            plan, contentSize: CGSize(width: 32000, height: 40000),
            baselineWidth: 800, unsplittable: spans
        )
        ExportPDFPagePlannerTests.assertRunIsolation(plan, runs: runs)
        ExportPDFPagePlannerTests.assertProsePagesStayAtBaseline(plan, runs: runs, baseline: 800)
        let firstRun = plan.pages.filter {
            $0.rect.minY >= 14998 - 0.5 && $0.rect.maxY <= 16000 + 0.5
        }
        let secondRun = plan.pages.filter {
            $0.rect.minY >= 16000 - 0.5 && $0.rect.maxY <= 17000 + 0.5
        }
        XCTAssertEqual(
            firstRun.map(\.rect.width),
            [20000 + ExportPDFPagePlanner.widePageSlack]
        )
        XCTAssertEqual(
            secondRun.map(\.rect.width),
            [30000 + ExportPDFPagePlanner.widePageSlack]
        )
        XCTAssertEqual(secondRun.first?.rect.minY ?? 0, 16000, accuracy: 0.5)
        // No empty slice at the shared edge: the old [16000,16040]-style page is
        // impossible — every page intersects a span (the invariant asserts this).
        XCTAssertFalse(plan.pages.contains { $0.rect.height < 10 })
    }

    /// X1, the [0–28] reproduction: a document that begins with a small leading gap
    /// and then a very wide run emits no whitespace-only first page — the run
    /// absorbs the gap and the first page grows into the run's first spans.
    func testDocumentStartingWithAWideRunEmitsNoLeadingBlankPage() throws {
        let spans = ExportPDFPagePlannerTests.lineSpans(from: 30, to: 40000)
        let extent = Extent(minY: 35, maxY: 5000, maxX: 180_097)
        let plan = try ExportPDFPagePlannerTests.planRunDocument(
            width: 180_097, height: 40000, unsplittable: spans, extents: [extent]
        )
        ExportPDFPagePlannerTests.assertPlanInvariants(
            plan, contentSize: CGSize(width: 180_097, height: 40000),
            baselineWidth: 800, unsplittable: spans
        )
        ExportPDFPagePlannerTests.assertRunIsolation(plan, runs: [(0, 5010)])
        let first = try XCTUnwrap(plan.pages.first)
        XCTAssertEqual(first.rect.minY, 0)
        // The first page reaches well past the 30 pt margin — no [0–28]-style
        // whitespace sliver survives.
        XCTAssertGreaterThan(first.rect.maxY, 30 + 0.5)
        XCTAssertFalse(plan.pages.contains { $0.rect.maxY <= 30 + 0.5 })
    }

    /// X1, the A4 Print reproduction: two wide runs separated only by a span-free
    /// gap both claim the gap and merge — no page can be emitted inside it.
    func testTwoAdjacentWideRunsWithASpanFreeGapMergeInPrint() throws {
        var spans = ExportPDFPagePlannerTests.lineSpans(to: 2000)
        spans.append(Span(minY: 2100, maxY: 2600))
        spans.append(Span(minY: 2700, maxY: 3200))
        spans.append(contentsOf: ExportPDFPagePlannerTests.lineSpans(from: 3300, to: 10000))
        let extents = [
            Extent(minY: 2150, maxY: 2550, maxX: 1500),
            Extent(minY: 2750, maxY: 3150, maxX: 1500),
        ]
        let plan = try ExportPDFPagePlannerTests.planRunDocument(
            width: 4000, height: 10000, unsplittable: spans,
            extents: extents, aspect: 1.0
        )
        ExportPDFPagePlannerTests.assertPlanInvariants(
            plan, contentSize: CGSize(width: 4000, height: 10000),
            baselineWidth: 800, unsplittable: spans, aspect: 1.0
        )
        // The (2600,2700) gap is claimed from both sides: the runs overlap after
        // absorption and merge. The merged top climbs to the last line span's edge
        // before the first atomic box (2,000), the bottom to the first line span
        // after the second (3,300): [2000, 3300].
        let runs: [(minY: CGFloat, maxY: CGFloat)] = [(2000, 3300)]
        ExportPDFPagePlannerTests.assertRunIsolation(plan, runs: runs)
        ExportPDFPagePlannerTests.assertProsePagesStayAtBaseline(plan, runs: runs, baseline: 800)
        let runPages = plan.pages.filter {
            $0.rect.minY >= 2000 - 0.5 && $0.rect.maxY <= 3300 + 0.5
        }
        let runPage = try XCTUnwrap(runPages.first)
        XCTAssertEqual(runPages.count, 1)
        XCTAssertEqual(runPage.rect.minY, 2000, accuracy: 0.5)
        XCTAssertEqual(runPage.rect.maxY, 3300, accuracy: 0.5)
        XCTAssertEqual(runPage.rect.width, 1500)
        // No page may sit wholly inside the span-free gap.
        XCTAssertFalse(plan.pages.contains {
            $0.rect.minY > 2600 - 0.5 && $0.rect.maxY < 2700 + 0.5
        })
    }
}
