import CoreGraphics
@testable import PreviewKit
import XCTest

final class ExportPDFPagePlannerAspectTests: XCTestCase {
    typealias Span = ExportPDFPagePlanner.Span

    func testTargetAspectBoundsPageHeightToThePaperAspect() throws {
        // Letter-portrait-ish aspect: budget = 800 × (11in/8.5in ≈ 1.294) ≈ 1035.
        let size = CGSize(width: 800, height: 3000)
        let spans = (0 ..< 100).map { Span(minY: CGFloat($0) * 30, maxY: CGFloat($0) * 30 + 28) }
        let plan = try ExportPDFPagePlanner.plan(
            contentSize: size,
            baselineWidth: 800,
            unsplittable: spans,
            widthExtents: [],
            targetAspect: 1.294
        )
        ExportPDFPagePlannerTests.assertPlanInvariants(
            plan, contentSize: size, baselineWidth: 800, unsplittable: spans, aspect: 1.294
        )
        ExportPDFPagePlannerTests.assertBreaksAreSafe(plan, unsplittable: spans)
        XCTAssertGreaterThan(plan.pages.count, 1)
    }

    func testDegenerateAspectIsIgnored() throws {
        let size = CGSize(width: 800, height: 30000)
        for aspect: CGFloat in [.nan, .infinity, 0, 0.005] {
            let plan = try ExportPDFPagePlanner.plan(
                contentSize: size,
                baselineWidth: 800,
                unsplittable: [],
                widthExtents: [],
                targetAspect: aspect
            )
            // No aspect → pure PDF budgeting: 14,400 pt pages.
            XCTAssertEqual(plan.pages.first?.rect.height ?? 0, 14400, accuracy: 0.5)
        }
    }
}
