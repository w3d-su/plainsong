import CoreGraphics
@testable import PreviewKit
import XCTest

/// Synthetic-geometry coverage for the variable-height, per-page-width planner
/// (`docs/export-gates.md` D4): oversize atomic boxes, container-child gaps, line-box
/// gaps, touching vs overlapping spans, the per-page scale, the hard 14,400 pt cap,
/// and the Print aspect budget. Per-page width and soft-extension cases live in
/// `ExportPDFPagePlannerWidthTests`.
final class ExportPDFPagePlannerTests: XCTestCase {
    typealias Span = ExportPDFPagePlanner.Span

    /// The planner invariants: contiguous coverage of [0, contentHeight], no page taller
    /// than its width's hard budget — the flat 14,400 CSS pt, lowered once the page's
    /// capture width would push the raster past `captureAreaBudget` — every page
    /// intersecting at least one unsplittable span when spans were supplied (strict
    /// overlap > ε: borders and padding count because the measured spans include
    /// them), every width inside [baseline, contentWidth + widePageSlack], and every
    /// page's scale equal to `pageScale` of its own capture width. Under an aspect, a
    /// page taller than its soft budget is allowed only when an unbreakable run spans
    /// it or the overage is whitespace swallowed up to a mandatory break.
    static func assertPlanInvariants(
        _ plan: ExportPDFPagePlanner.Plan,
        contentSize: CGSize,
        baselineWidth: CGFloat,
        unsplittable: [Span],
        aspect: CGFloat? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let epsilon: CGFloat = 0.5
        let baseline = min(contentSize.width, max(baselineWidth, 1))
        XCTAssertFalse(plan.pages.isEmpty, file: file, line: line)
        var expectedTop: CGFloat = 0
        for page in plan.pages {
            let rect = page.rect
            XCTAssertEqual(rect.minX, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(rect.width, baseline - 0.001, file: file, line: line)
            XCTAssertLessThanOrEqual(
                rect.width,
                contentSize.width + ExportPDFPagePlanner.widePageSlack + 0.001,
                file: file, line: line
            )
            XCTAssertEqual(rect.minY, expectedTop, accuracy: 0.001, file: file, line: line)
            XCTAssertGreaterThan(rect.height, 0.001, file: file, line: line)
            if !unsplittable.isEmpty {
                XCTAssertTrue(
                    unsplittable.contains {
                        $0.minY < rect.maxY - epsilon && $0.maxY > rect.minY + epsilon
                    },
                    "Page \(rect) intersects no unsplittable span — it would be blank",
                    file: file, line: line
                )
            }
            let scale = ExportPDFPagePlanner.pageScale(width: rect.width)
            XCTAssertEqual(page.scale, scale, accuracy: 0.0001, file: file, line: line)
            let hard = min(
                ExportPDFPagePlanner.maximumSide,
                ExportPDFPagePlanner.captureAreaBudget / max(rect.width, 1)
            )
            XCTAssertLessThanOrEqual(rect.height, hard + 0.001, file: file, line: line)
            if let aspect {
                let soft = min(hard, rect.width * aspect)
                // The final page may end at the content's own end even past the soft
                // budget; any other overage needs an unbreakable run that spans the
                // soft-budget position and reaches the page's own end — whether the
                // page top sits inside it or the page grew over leading whitespace —
                // or a purely whitespace overage swallowed up to a mandatory break.
                let reachesContentEnd = rect.maxY >= contentSize.height - epsilon
                if rect.height > soft + epsilon, !reachesContentEnd {
                    let overageStart = rect.minY + soft
                    let spansPage = unsplittable.contains { span in
                        span.minY <= overageStart + epsilon
                            && span.maxY > rect.maxY - epsilon
                    }
                    let overageIsWhitespace = !unsplittable.contains { span in
                        span.minY < rect.maxY - epsilon
                            && span.maxY > overageStart + epsilon
                    }
                    XCTAssertTrue(
                        spansPage || overageIsWhitespace,
                        "Page at \(rect.minY) exceeds its soft budget without an "
                            + "unbreakable run spanning it",
                        file: file, line: line
                    )
                }
            }
            expectedTop = rect.maxY
        }
        // Pages cover [0, contentHeight] contiguously — except that a fully span-free
        // tail may be dropped as the B2 safety net; nothing but whitespace can follow
        // the last kept page.
        if expectedTop < contentSize.height - epsilon {
            for span in unsplittable {
                XCTAssertLessThanOrEqual(
                    span.maxY, expectedTop + epsilon,
                    "Content at \(span.minY)…\(span.maxY) lies past the dropped tail",
                    file: file, line: line
                )
            }
        } else {
            XCTAssertEqual(expectedTop, contentSize.height, accuracy: 0.001, file: file, line: line)
        }
    }

    /// Fills [start, end) with line-box-like spans `height` tall every `step`, like the
    /// spans a paragraph's line boxes produce — interior safe breaks between them keep
    /// tests exercising the page loop instead of one giant interval.
    static func lineSpans(
        from start: CGFloat = 0,
        to end: CGFloat,
        step: CGFloat = 30,
        height: CGFloat = 28
    ) -> [Span] {
        var spans: [Span] = []
        var top = start
        while top < end {
            spans.append(Span(minY: top, maxY: min(top + height, end)))
            top += step
        }
        return spans
    }

    /// Every page boundary must land on a safe break: never strictly inside a merged
    /// unbreakable interval. A soft-extended page's bottom is a run's end, which is
    /// still outside every interval's interior.
    static func assertBreaksAreSafe(
        _ plan: ExportPDFPagePlanner.Plan,
        unsplittable: [Span],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for page in plan.pages.dropLast() {
            let boundary = page.rect.maxY
            for span in unsplittable {
                XCTAssertFalse(
                    span.minY + 0.5 < boundary && boundary < span.maxY - 0.5,
                    "Break at \(boundary) cuts span \(span.minY)…\(span.maxY)",
                    file: file, line: line
                )
            }
        }
    }

    private func planDocument(
        width: CGFloat,
        height: CGFloat,
        unsplittable: [Span] = [],
        extents: [ExportPDFPagePlanner.WidthExtent] = [],
        aspect: CGFloat? = nil
    ) throws -> ExportPDFPagePlanner.Plan {
        try ExportPDFPagePlanner.plan(
            contentSize: CGSize(width: width, height: height),
            baselineWidth: width,
            unsplittable: unsplittable,
            widthExtents: extents,
            targetAspect: aspect
        )
    }

    func testOversizeAtomicBoxThrowsATypedError() {
        // 14,500 pt tall: strictly over the 14,400 hard cap so no page can hold it.
        let atomic = Span(minY: 100, maxY: 14600)
        XCTAssertThrowsError(
            try ExportPDFPagePlanner.plan(
                contentSize: CGSize(width: 800, height: 16000),
                baselineWidth: 800,
                unsplittable: [atomic],
                widthExtents: []
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

    func testOversizeAtomicBoxReportsTheRunHeightInCSSPoints() {
        // The cap is a flat 14,400 CSS pt: a 30,000 pt unbreakable interval throws and
        // reports its CSS height, no matter the page width (28,800 pt → scale 0.5).
        XCTAssertThrowsError(
            try ExportPDFPagePlanner.plan(
                contentSize: CGSize(width: 28800, height: 40000),
                baselineWidth: 28800,
                unsplittable: [Span(minY: 0, maxY: 30000)],
                widthExtents: []
            )
        ) { error in
            guard let captureError = error as? ExportPDFCaptureError,
                  case let .oversizeAtomicBox(heightPoints) = captureError
            else {
                return XCTFail("Expected oversizeAtomicBox, got \(error)")
            }
            XCTAssertEqual(heightPoints, 30000, accuracy: 0.5)
        }
    }

    /// The hard cap binds under an aspect too: a soft extension may pass the soft
    /// budget, but a run taller than `hard(width)` still throws.
    func testOversizeAtomicBoxThrowsPastTheHardCapUnderAnAspect() {
        let atomic = Span(minY: 100, maxY: 14600)
        XCTAssertThrowsError(
            try ExportPDFPagePlanner.plan(
                contentSize: CGSize(width: 800, height: 16000),
                baselineWidth: 800,
                unsplittable: [atomic],
                widthExtents: [],
                targetAspect: 1.29
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

    func testSevenHundredItemListBreaksBetweenItems() throws {
        // Adjacent li children: touching spans of ~28 pt each.
        var spans: [Span] = []
        for index in 0 ..< 700 {
            let top = CGFloat(index) * 28
            spans.append(Span(minY: top, maxY: top + 26))
        }
        let plan = try planDocument(width: 800, height: 19600, unsplittable: spans)
        Self.assertPlanInvariants(
            plan, contentSize: CGSize(width: 800, height: 19600),
            baselineWidth: 800, unsplittable: spans
        )
        Self.assertBreaksAreSafe(plan, unsplittable: spans)
        XCTAssertGreaterThan(plan.pages.count, 1)
    }

    func testEightHundredLinePreBreaksBetweenLineBoxes() throws {
        // pre line boxes: touching spans, 18 pt each.
        var spans: [Span] = []
        for index in 0 ..< 800 {
            let top = CGFloat(index) * 18
            spans.append(Span(minY: top, maxY: top + 18))
        }
        let plan = try planDocument(width: 800, height: 14400, unsplittable: spans)
        Self.assertPlanInvariants(
            plan, contentSize: CGSize(width: 800, height: 14400),
            baselineWidth: 800, unsplittable: spans
        )
        Self.assertBreaksAreSafe(plan, unsplittable: spans)
        XCTAssertEqual(plan.pages.count, 1)
    }

    func testTwoThousandRowTableBreaksExactlyOnRowEdges() throws {
        // 2,000 touching rows: the shared edges are the only safe breaks.
        var spans: [Span] = []
        for index in 0 ..< 2000 {
            let top = CGFloat(index) * 20
            spans.append(Span(minY: top, maxY: top + 20))
        }
        let plan = try planDocument(width: 800, height: 40000, unsplittable: spans)
        Self.assertPlanInvariants(
            plan, contentSize: CGSize(width: 800, height: 40000),
            baselineWidth: 800, unsplittable: spans
        )
        Self.assertBreaksAreSafe(plan, unsplittable: spans)
        XCTAssertEqual(plan.pages.count, 3)
        for page in plan.pages.dropLast() {
            XCTAssertEqual(page.rect.maxY.truncatingRemainder(dividingBy: 20), 0, accuracy: 0.001)
        }
    }

    func testParagraphTallerThanAPageBreaksBetweenItsLineBoxes() throws {
        // One paragraph: a single block element whose line boxes are unsplittable.
        var spans: [Span] = []
        for index in 0 ..< 2000 {
            let top = CGFloat(index) * 18
            spans.append(Span(minY: top, maxY: top + 16))
        }
        let plan = try planDocument(width: 800, height: 36000, unsplittable: spans)
        Self.assertPlanInvariants(
            plan, contentSize: CGSize(width: 800, height: 36000),
            baselineWidth: 800, unsplittable: spans
        )
        Self.assertBreaksAreSafe(plan, unsplittable: spans)
        XCTAssertEqual(plan.pages.count, 3)
    }

    func testTouchingSpansKeepTheirSharedEdgeAsABreak() throws {
        // Two touching blocks; a boundary on their shared edge is safe.
        let spans = [Span(minY: 0, maxY: 14000), Span(minY: 14000, maxY: 28000)]
        let plan = try planDocument(width: 800, height: 28000, unsplittable: spans)
        XCTAssertEqual(plan.pages.count, 2)
        XCTAssertEqual(plan.pages[0].rect.maxY, 14000, accuracy: 0.5)
    }

    func testOverlappingSpansBreakAtTheUnionMinYNotAnInteriorEdge() throws {
        // A [9000,14000] and B [13800,14500] overlap by 200 pt and merge into one
        // unbreakable run [9000,14500]. If they had not merged, the 14,400 target would
        // land inside B alone and offer the interior edge 13,800; merged, the page must
        // end at the union's minY = 9,000.
        let spans = [Span(minY: 9000, maxY: 14000), Span(minY: 13800, maxY: 14500)]
        let plan = try planDocument(width: 800, height: 16000, unsplittable: spans)
        XCTAssertEqual(plan.pages.count, 2)
        XCTAssertEqual(plan.pages[0].rect.maxY, 9000, accuracy: 0.5)
    }

    func testOverlappingSpansFormAnUnbreakableRunTallerThanTheBudget() {
        // A run of overlapping spans merging to [0,15000] is taller than the budget:
        // no interior edge is offered and planning fails as oversize.
        let spans = [
            Span(minY: 0, maxY: 14000),
            Span(minY: 13800, maxY: 15000),
            Span(minY: 15000, maxY: 16000),
        ]
        XCTAssertThrowsError(try planDocument(width: 800, height: 16000, unsplittable: spans)) { error in
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
        let plan = try planDocument(
            width: 800, height: 3000, unsplittable: spans, aspect: 1.294
        )
        Self.assertPlanInvariants(
            plan, contentSize: CGSize(width: 800, height: 3000),
            baselineWidth: 800, unsplittable: spans, aspect: 1.294
        )
        Self.assertBreaksAreSafe(plan, unsplittable: spans)
        XCTAssertGreaterThan(plan.pages.count, 1)
    }

    func testPageWiderThanTheMaximumIsStillCappedAtTheMaximumSide() throws {
        // Page width 28,800 → scale ≈ 0.497 (14,400 / 29,000 — the past-cap page
        // also captures `widePageSlack` of overscan) — but the height budget
        // stays a flat 14,400 CSS pt: a 40,000 pt document needs 3 pages, and
        // WebKit never sees a taller-than-maximum capture.
        let spans = (0 ..< 400).map { Span(minY: CGFloat($0) * 100, maxY: CGFloat($0) * 100 + 90) }
        let plan = try planDocument(width: 28800, height: 40000, unsplittable: spans)
        Self.assertPlanInvariants(
            plan, contentSize: CGSize(width: 28800, height: 40000),
            baselineWidth: 28800, unsplittable: spans
        )
        Self.assertBreaksAreSafe(plan, unsplittable: spans)
        XCTAssertEqual(plan.pages.count, 3)
        let capture = 28800 + ExportPDFPagePlanner.widePageSlack
        for page in plan.pages {
            XCTAssertEqual(page.rect.width, capture)
            XCTAssertLessThanOrEqual(page.rect.height, 14400 + 0.5)
            XCTAssertEqual(
                page.scale,
                ExportPDFPagePlanner.pageScale(width: capture),
                accuracy: 0.0001
            )
        }
    }

    /// Landscape paper (A4 landscape imageable 783 × 559 → aspect ≈ 0.714) makes every
    /// non-extended page wider than tall.
    /// A non-finite or implausibly small aspect is treated as no aspect.
    func testDegenerateAspectIsIgnored() throws {
        for aspect: CGFloat in [.nan, .infinity, 0, 0.005] {
            let plan = try planDocument(width: 800, height: 30000, aspect: aspect)
            // No aspect → pure PDF budgeting: 14,400 pt pages.
            XCTAssertEqual(plan.pages.first?.rect.height ?? 0, 14400, accuracy: 0.5)
        }
    }

    func testEmptySpanListSplitsAtTheBudget() throws {
        let plan = try planDocument(width: 800, height: 30000)
        Self.assertPlanInvariants(
            plan, contentSize: CGSize(width: 800, height: 30000),
            baselineWidth: 800, unsplittable: []
        )
        XCTAssertEqual(plan.pages.count, 3)
        XCTAssertEqual(plan.pages[0].rect.height, 14400, accuracy: 0.5)
        XCTAssertEqual(plan.pages[1].rect.height, 14400, accuracy: 0.5)
    }

    func testZeroHeightTailDoesNotProduceAnEmptyPage() throws {
        // Last span ends exactly at the budget edge; nothing after it should emit a page.
        let plan = try planDocument(width: 800, height: 14400, unsplittable: [Span(minY: 0, maxY: 14400)])
        XCTAssertEqual(plan.pages.count, 1)
    }

    func testPageScaleShrinksOnlyPastTheMaximum() {
        XCTAssertEqual(ExportPDFPagePlanner.pageScale(width: 800), 1)
        XCTAssertEqual(ExportPDFPagePlanner.pageScale(width: 14400), 1)
        let shrunk = ExportPDFPagePlanner.pageScale(width: 28800)
        XCTAssertEqual(shrunk, 0.5, accuracy: 0.0001)
        XCTAssertEqual(28800 * shrunk, 14400, accuracy: 0.1)
    }
}
