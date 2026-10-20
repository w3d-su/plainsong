import CoreGraphics
@testable import PreviewKit
import XCTest

final class ExportPDFPagePlannerRegressionTests: XCTestCase {
    func testSeed551550976DoesNotEmitTheLeadingGapAsABlankPage() throws {
        let seed = 551_550_976
        let spans = [
            ExportPDFPagePlanner.Span(minY: 0, maxY: 40),
            ExportPDFPagePlanner.Span(minY: 172, maxY: 10851.6396812749),
            ExportPDFPagePlanner.Span(minY: 10866.6396812749, maxY: 20076.225798113388),
        ]
        let extents = [
            ExportPDFPagePlanner.WidthExtent(
                minY: 172, maxY: 10851.6396812749, maxX: 50000
            ),
            ExportPDFPagePlanner.WidthExtent(
                minY: 10866.6396812749, maxY: 20076.225798113388, maxX: 58000
            ),
        ]
        let plan = try ExportPDFPagePlanner.plan(
            contentSize: CGSize(width: 58000, height: 20713.225798113388),
            baselineWidth: 800,
            unsplittable: spans,
            widthExtents: extents,
            targetAspect: 1.29
        )

        var previousBottom: CGFloat = 0
        for page in plan.pages {
            let rect = page.rect
            XCTAssertGreaterThanOrEqual(rect.minY, previousBottom - 0.5, "seed \(seed)")
            if rect.minY > previousBottom + 0.5 {
                XCTAssertFalse(
                    spans.contains {
                        $0.minY < rect.minY - 0.5 && $0.maxY > previousBottom + 0.5
                    },
                    "seed \(seed): uncovered strip contains content"
                )
            }
            XCTAssertTrue(
                spans.contains {
                    $0.minY < rect.maxY - 0.5 && $0.maxY > rect.minY + 0.5
                },
                "seed \(seed): blank page \(rect)"
            )
            previousBottom = rect.maxY
        }
    }
}
