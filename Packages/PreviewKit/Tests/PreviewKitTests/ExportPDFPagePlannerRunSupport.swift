import CoreGraphics
@testable import PreviewKit
import XCTest

/// Wide-run helpers shared between `ExportPDFPagePlannerRunTests` and
/// `ExportPDFPagePlannerGapTests` (`docs/export-gates.md` D4): the document
/// planner entry point and the run-isolation assertions.
extension ExportPDFPagePlannerTests {
    static func planRunDocument(
        width: CGFloat,
        height: CGFloat,
        baselineWidth: CGFloat = 800,
        unsplittable: [Span] = [],
        extents: [ExportPDFPagePlanner.WidthExtent] = [],
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
    static func assertRunIsolation(
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
    static func assertProsePagesStayAtBaseline(
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
}
