import CoreGraphics
@testable import PreviewKit
import XCTest

/// Synthetic-geometry coverage for the A1 variable-height planner
/// (`docs/export-gates.md` D4): oversize atomic boxes, container-child gaps, line-box
/// gaps, touching vs overlapping spans, the scale budget, and the Print aspect budget.
final class ExportPDFPagePlannerTests: XCTestCase {
    private typealias Span = ExportPDFPagePlanner.Span

    /// The planner invariants: contiguous coverage of [0, contentHeight], no page taller
    /// than the budget, no empty page, uniform width.
    private func assertPlanInvariants(
        _ plan: ExportPDFPagePlanner.Plan,
        contentSize: CGSize,
        budget: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(plan.pageRects.isEmpty, file: file, line: line)
        var expectedTop: CGFloat = 0
        for rect in plan.pageRects {
            XCTAssertEqual(rect.minX, 0, file: file, line: line)
            XCTAssertEqual(rect.width, contentSize.width, file: file, line: line)
            XCTAssertEqual(rect.minY, expectedTop, accuracy: 0.001, file: file, line: line)
            XCTAssertGreaterThan(rect.height, 0.001, file: file, line: line)
            XCTAssertLessThanOrEqual(rect.height, budget + 0.001, file: file, line: line)
            expectedTop = rect.maxY
        }
        XCTAssertEqual(expectedTop, contentSize.height, accuracy: 0.001, file: file, line: line)
    }

    /// Every page boundary must land on a safe break: never strictly inside a merged
    /// unbreakable interval.
    private func assertBreaksAreSafe(
        _ plan: ExportPDFPagePlanner.Plan,
        unsplittable: [Span],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for rect in plan.pageRects.dropLast() {
            let boundary = rect.maxY
            for span in unsplittable {
                XCTAssertFalse(
                    span.minY + 0.5 < boundary && boundary < span.maxY - 0.5,
                    "Break at \(boundary) cuts span \(span.minY)…\(span.maxY)",
                    file: file, line: line
                )
            }
        }
    }

    func testOversizeAtomicBoxThrowsATypedError() {
        // 14,500 pt tall: strictly over the 14,400 budget so no page can hold it.
        let atomic = Span(minY: 100, maxY: 14600)
        XCTAssertThrowsError(
            try ExportPDFPagePlanner.plan(
                contentSize: CGSize(width: 800, height: 16000),
                unsplittable: [atomic],
                scale: 1
            )
        ) { error in
            guard let captureError = error as? ExportPDFCaptureError,
                  case let .oversizeAtomicBox(heightPoints) = captureError
            else {
                return XCTFail("Expected oversizeAtomicBox, got \(error)")
            }
            XCTAssertEqual(heightPoints, 14500, accuracy: 0.5)
        }
    }

    func testOversizeAtomicBoxReportsScaledHeight() {
        XCTAssertThrowsError(
            try ExportPDFPagePlanner.plan(
                contentSize: CGSize(width: 28800, height: 40000),
                unsplittable: [Span(minY: 0, maxY: 30000)],
                scale: 0.5
            )
        ) { error in
            guard let captureError = error as? ExportPDFCaptureError,
                  case let .oversizeAtomicBox(heightPoints) = captureError
            else {
                return XCTFail("Expected oversizeAtomicBox, got \(error)")
            }
            XCTAssertEqual(heightPoints, 15000, accuracy: 0.5)
        }
    }

    func testSevenHundredItemListBreaksBetweenItems() throws {
        // Adjacent li children: touching spans of ~28 pt each.
        var spans: [Span] = []
        for index in 0 ..< 700 {
            let top = CGFloat(index) * 28
            spans.append(Span(minY: top, maxY: top + 26))
        }
        let plan = try ExportPDFPagePlanner.plan(
            contentSize: CGSize(width: 800, height: 19600),
            unsplittable: spans,
            scale: 1
        )
        assertPlanInvariants(plan, contentSize: CGSize(width: 800, height: 19600), budget: 14400)
        assertBreaksAreSafe(plan, unsplittable: spans)
        XCTAssertGreaterThan(plan.pageRects.count, 1)
    }

    func testEightHundredLinePreBreaksBetweenLineBoxes() throws {
        // pre line boxes: touching spans, 18 pt each.
        var spans: [Span] = []
        for index in 0 ..< 800 {
            let top = CGFloat(index) * 18
            spans.append(Span(minY: top, maxY: top + 18))
        }
        let plan = try ExportPDFPagePlanner.plan(
            contentSize: CGSize(width: 800, height: 14400),
            unsplittable: spans,
            scale: 1
        )
        assertPlanInvariants(plan, contentSize: CGSize(width: 800, height: 14400), budget: 14400)
        assertBreaksAreSafe(plan, unsplittable: spans)
        XCTAssertEqual(plan.pageRects.count, 1)
    }

    func testTwoThousandRowTableBreaksExactlyOnRowEdges() throws {
        // 2,000 touching rows: the shared edges are the only safe breaks.
        var spans: [Span] = []
        for index in 0 ..< 2000 {
            let top = CGFloat(index) * 20
            spans.append(Span(minY: top, maxY: top + 20))
        }
        let plan = try ExportPDFPagePlanner.plan(
            contentSize: CGSize(width: 800, height: 40000),
            unsplittable: spans,
            scale: 1
        )
        assertPlanInvariants(plan, contentSize: CGSize(width: 800, height: 40000), budget: 14400)
        assertBreaksAreSafe(plan, unsplittable: spans)
        XCTAssertEqual(plan.pageRects.count, 3)
        for rect in plan.pageRects.dropLast() {
            XCTAssertEqual(rect.maxY.truncatingRemainder(dividingBy: 20), 0, accuracy: 0.001)
        }
    }

    func testParagraphTallerThanAPageBreaksBetweenItsLineBoxes() throws {
        // One paragraph: a single block element whose line boxes are unsplittable.
        var spans: [Span] = []
        for index in 0 ..< 2000 {
            let top = CGFloat(index) * 18
            spans.append(Span(minY: top, maxY: top + 16))
        }
        let plan = try ExportPDFPagePlanner.plan(
            contentSize: CGSize(width: 800, height: 36000),
            unsplittable: spans,
            scale: 1
        )
        assertPlanInvariants(plan, contentSize: CGSize(width: 800, height: 36000), budget: 14400)
        assertBreaksAreSafe(plan, unsplittable: spans)
        XCTAssertEqual(plan.pageRects.count, 3)
    }

    func testTouchingSpansKeepTheirSharedEdgeAsABreak() throws {
        // Two touching blocks; a boundary on their shared edge is safe.
        let spans = [Span(minY: 0, maxY: 14000), Span(minY: 14000, maxY: 28000)]
        let plan = try ExportPDFPagePlanner.plan(
            contentSize: CGSize(width: 800, height: 28000),
            unsplittable: spans,
            scale: 1
        )
        XCTAssertEqual(plan.pageRects.count, 2)
        XCTAssertEqual(plan.pageRects[0].maxY, 14000, accuracy: 0.5)
    }

    func testOverlappingSpansBreakAtTheUnionMinYNotAnInteriorEdge() throws {
        // A [9000,14000] and B [13800,14500] overlap by 200 pt and merge into one
        // unbreakable run [9000,14500]. If they had not merged, the 14,400 target would
        // land inside B alone and offer the interior edge 13,800; merged, the page must
        // end at the union's minY = 9,000.
        let spans = [Span(minY: 9000, maxY: 14000), Span(minY: 13800, maxY: 14500)]
        let plan = try ExportPDFPagePlanner.plan(
            contentSize: CGSize(width: 800, height: 16000),
            unsplittable: spans,
            scale: 1
        )
        XCTAssertEqual(plan.pageRects.count, 2)
        XCTAssertEqual(plan.pageRects[0].maxY, 9000, accuracy: 0.5)
    }

    func testOverlappingSpansFormAnUnbreakableRunTallerThanTheBudget() {
        // A run of overlapping spans merging to [0,15000] is taller than the budget:
        // no interior edge is offered and planning fails as oversize.
        let spans = [
            Span(minY: 0, maxY: 14000),
            Span(minY: 13800, maxY: 15000),
            Span(minY: 15000, maxY: 16000),
        ]
        XCTAssertThrowsError(
            try ExportPDFPagePlanner.plan(
                contentSize: CGSize(width: 800, height: 16000),
                unsplittable: spans,
                scale: 1
            )
        ) { error in
            guard let captureError = error as? ExportPDFCaptureError,
                  case .oversizeAtomicBox = captureError
            else {
                return XCTFail("Expected oversizeAtomicBox, got \(error)")
            }
        }
    }

    func testTargetAspectBoundsPageHeightToThePaperAspect() throws {
        // Letter-portrait-ish aspect: budget = 800 × (11in/8.5in ≈ 1.294) ≈ 1035.
        let spans = (0 ..< 100).map { Span(minY: CGFloat($0) * 30, maxY: CGFloat($0) * 30 + 28) }
        let plan = try ExportPDFPagePlanner.plan(
            contentSize: CGSize(width: 800, height: 3000),
            unsplittable: spans,
            scale: 1,
            targetAspect: 1.294
        )
        let budget = 800 * 1.294
        assertPlanInvariants(plan, contentSize: CGSize(width: 800, height: 3000), budget: budget)
        XCTAssertGreaterThan(plan.pageRects.count, 1)
    }

    func testScaleBelowOneRaisesTheCSSHeightBudget() throws {
        // Scale 0.5 → budget 28,800 CSS px for a 40,000 px document → 2 pages.
        let spans = (0 ..< 400).map { Span(minY: CGFloat($0) * 100, maxY: CGFloat($0) * 100 + 90) }
        let plan = try ExportPDFPagePlanner.plan(
            contentSize: CGSize(width: 28800, height: 40000),
            unsplittable: spans,
            scale: 0.5
        )
        assertPlanInvariants(
            plan, contentSize: CGSize(width: 28800, height: 40000), budget: 28800
        )
        assertBreaksAreSafe(plan, unsplittable: spans)
        XCTAssertEqual(plan.pageRects.count, 2)
    }

    func testEmptySpanListSplitsAtTheBudget() throws {
        let plan = try ExportPDFPagePlanner.plan(
            contentSize: CGSize(width: 800, height: 30000),
            unsplittable: [],
            scale: 1
        )
        assertPlanInvariants(plan, contentSize: CGSize(width: 800, height: 30000), budget: 14400)
        XCTAssertEqual(plan.pageRects.count, 3)
        XCTAssertEqual(plan.pageRects[0].height, 14400, accuracy: 0.5)
        XCTAssertEqual(plan.pageRects[1].height, 14400, accuracy: 0.5)
    }

    func testZeroHeightTailDoesNotProduceAnEmptyPage() throws {
        // Last span ends exactly at the budget edge; nothing after it should emit a page.
        let spans = [Span(minY: 0, maxY: 14400)]
        let plan = try ExportPDFPagePlanner.plan(
            contentSize: CGSize(width: 800, height: 14400),
            unsplittable: spans,
            scale: 1
        )
        XCTAssertEqual(plan.pageRects.count, 1)
    }

    func testUniformScaleShrinksOnlyPastTheMaximum() {
        XCTAssertEqual(ExportPDFPagePlanner.uniformScale(containedWidth: 800), 1)
        XCTAssertEqual(ExportPDFPagePlanner.uniformScale(containedWidth: 14400), 1)
        let shrunk = ExportPDFPagePlanner.uniformScale(containedWidth: 28800)
        XCTAssertEqual(shrunk, 0.5, accuracy: 0.0001)
        XCTAssertEqual(28800 * shrunk, 14400, accuracy: 0.1)
    }

    func testJoinedPagesKeepEachMediaBox() throws {
        let first = try Self.page(width: 200, height: 100)
        let second = try Self.page(width: 180, height: 90)
        let joined = try ExportPDFPageJoiner.join([first, second], scale: 1)
        guard let document = CGPDFDocument(CGDataProvider(data: joined as CFData)!) else {
            return XCTFail("Joined data is not a PDF")
        }
        XCTAssertEqual(document.numberOfPages, 2)
        XCTAssertEqual(document.page(at: 1)?.getBoxRect(.mediaBox).height ?? 0, 100, accuracy: 0.5)
        XCTAssertEqual(document.page(at: 2)?.getBoxRect(.mediaBox).height ?? 0, 90, accuracy: 0.5)
    }

    func testJoinerScaleShrinksTheMediaBox() throws {
        let page = try Self.page(width: 200, height: 100)
        let joined = try ExportPDFPageJoiner.join([page], scale: 0.5)
        guard let document = CGPDFDocument(CGDataProvider(data: joined as CFData)!) else {
            return XCTFail("Joined data is not a PDF")
        }
        let box = try XCTUnwrap(document.page(at: 1)?.getBoxRect(.mediaBox))
        XCTAssertEqual(box.width, 100, accuracy: 0.5)
        XCTAssertEqual(box.height, 50, accuracy: 0.5)
    }

    private static func page(width: CGFloat, height: CGFloat) throws -> Data {
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let consumer = try XCTUnwrap(CGDataConsumer(data: output))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }
}
