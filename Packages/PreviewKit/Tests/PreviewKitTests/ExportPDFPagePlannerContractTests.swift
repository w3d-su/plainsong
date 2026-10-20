import CoreGraphics
@testable import PreviewKit
import XCTest

final class ExportPDFPagePlannerContractTests: XCTestCase {
    private typealias Span = ExportPDFPagePlanner.Span
    private typealias Extent = ExportPDFPagePlanner.WidthExtent

    func testGapOwnershipAroundTheHardBudgetForPDFAndPrint() throws {
        let budgets: [(width: CGFloat, aspect: CGFloat?)] = [
            (2000, nil), (2000, 1.29), (20000, nil), (20000, 1.29),
            (50000, nil), (50000, 1.29),
        ]
        for (width, aspect) in budgets {
            let capture = width + (width > 14400 ? ExportPDFPagePlanner.widePageSlack : 0)
            let hard = min(
                ExportPDFPagePlanner.maximumSide,
                ExportPDFPagePlanner.captureAreaBudget / capture
            )
            let soft = min(hard, capture * (aspect ?? 1))
            for leading in [false, true] {
                for trailing in [false, true] {
                    for delta: CGFloat in [-1, 0, 1] {
                        let gap: CGFloat = 16
                        let rowHeight = soft - gap + delta
                        let rowTop: CGFloat = leading ? gap : 0
                        let row = Span(minY: rowTop, maxY: rowTop + rowHeight)
                        let contentHeight = row.maxY + (trailing ? gap : 0)
                        let plan = try makePlan(
                            width: width, height: contentHeight,
                            spans: [row], extents: [Extent(
                                minY: row.minY, maxY: row.maxY, maxX: width
                            )], aspect: aspect
                        )
                        ExportPDFPagePlannerTests.assertPlanInvariants(
                            plan, contentSize: CGSize(width: width, height: contentHeight),
                            baselineWidth: 800, unsplittable: [row], aspect: aspect
                        )
                        XCTAssertTrue(
                            plan.pages.allSatisfy { page in
                                page.rect.minY < row.maxY - 0.5
                                    && page.rect.maxY > row.minY + 0.5
                            },
                            "width \(width), aspect \(String(describing: aspect)), "
                                + "leading \(leading), trailing \(trailing), delta \(delta)"
                        )
                    }
                }
            }
        }
    }

    func test286000PointRunKeepsTheHardBudgetMinus18RowAnd16PointGapsTogether() throws {
        let width: CGFloat = 286_000
        let hard = ExportPDFPagePlanner.captureAreaBudget
            / (width + ExportPDFPagePlanner.widePageSlack)
        let row = Span(minY: 16, maxY: 16 + hard - 18)
        let plan = try makePlan(
            width: width, height: row.maxY + 16, spans: [row],
            extents: [Extent(minY: row.minY, maxY: row.maxY, maxX: width)]
        )
        XCTAssertEqual(plan.pages.count, 1)
        let page = try XCTUnwrap(plan.pages.first)
        XCTAssertTrue(intersects(page.rect, row))
        XCTAssertLessThanOrEqual(page.rect.height, hard + 0.5)
        XCTAssertGreaterThanOrEqual(page.rect.maxY, row.maxY)
    }

    func test286200PointLeadingGapNeverBecomesAWhitespaceOnlyPage() throws {
        let width: CGFloat = 286_200
        let hard = ExportPDFPagePlanner.captureAreaBudget
            / (width + ExportPDFPagePlanner.widePageSlack)
        let row = Span(minY: 1030, maxY: 1030 + hard - 10)
        let plan = try makePlan(
            width: width, height: row.maxY, spans: [row],
            extents: [Extent(minY: row.minY, maxY: row.maxY, maxX: width)]
        )
        for page in plan.pages where page.rect.minY < 1030 {
            XCTAssertTrue(intersects(page.rect, row), "Whitespace-only page: \(page.rect)")
        }
    }

    func testLeadingWhitespaceExtentCannotExceedTheFinalCaptureAreaBudget() throws {
        let baseline: CGFloat = 800
        let contentWidth: CGFloat = 320_000
        let span = Span(minY: 1000, maxY: 2700)
        let extent = Extent(minY: 0, maxY: 1000, maxX: contentWidth)
        let size = CGSize(width: contentWidth, height: 2700)
        let plan = try ExportPDFPagePlanner.plan(
            contentSize: size, baselineWidth: baseline,
            unsplittable: [span], widthExtents: [extent], targetAspect: 1.29
        )
        ExportPDFPagePlannerTests.assertPlanInvariants(
            plan, contentSize: size, baselineWidth: baseline,
            unsplittable: [span], aspect: 1.29
        )
        let page = try XCTUnwrap(plan.pages.first)
        XCTAssertEqual(plan.pages.count, 1)
        XCTAssertEqual(page.rect.minY, span.minY, accuracy: 0.5)
        let hard = min(
            ExportPDFPagePlanner.maximumSide,
            ExportPDFPagePlanner.captureAreaBudget / page.rect.width
        )
        XCTAssertLessThanOrEqual(page.rect.height, hard)
        let originalTopWidth = contentWidth + ExportPDFPagePlanner.widePageSlack
        let originalTopHard = min(
            ExportPDFPagePlanner.maximumSide,
            ExportPDFPagePlanner.captureAreaBudget / originalTopWidth
        )
        XCTAssertGreaterThan(span.maxY, originalTopHard)
    }

    func testWhitespaceSeparatedWideRunsKeepTheirOwnPagesAndWidths() throws {
        let first = Span(minY: 100, maxY: 400)
        let second = Span(minY: 500, maxY: 900)
        let plan = try makePlan(
            width: 80000, height: 1000, spans: [first, second],
            extents: [
                Extent(minY: first.minY, maxY: first.maxY, maxX: 50000),
                Extent(minY: second.minY, maxY: second.maxY, maxX: 80000),
            ],
            aspect: 1.29
        )
        let firstPage = try XCTUnwrap(plan.pages.first { intersects($0.rect, first) })
        let secondPage = try XCTUnwrap(plan.pages.first { intersects($0.rect, second) })
        XCTAssertFalse(intersects(firstPage.rect, second))
        XCTAssertNotEqual(firstPage.rect.width, secondPage.rect.width)
        XCTAssertGreaterThan(firstPage.rect.width, 50000)
        XCTAssertGreaterThan(secondPage.rect.width, 80000)
    }

    func testG3ChecksTheWideBoxAtItsOwnCaptureWidth() throws {
        let row = Span(minY: 100, maxY: 719)
        let line = Span(minY: 900, maxY: 1020)
        let plan = try makePlan(
            width: 1_137_716, height: 1200, spans: [row, line],
            extents: [
                Extent(minY: row.minY, maxY: row.maxY, maxX: 22134),
                Extent(minY: line.minY, maxY: line.maxY, maxX: 1_137_716),
            ]
        )
        let rowPage = try XCTUnwrap(plan.pages.first { intersects($0.rect, row) })
        let linePage = try XCTUnwrap(plan.pages.first { intersects($0.rect, line) })
        XCTAssertLessThan(rowPage.rect.width, linePage.rect.width)
    }

    func testOversizeBoxReportsItsOwnCaptureWidthAndHeight() {
        let width: CGFloat = 180_000
        let box = Span(minY: 1000, maxY: 11000)
        XCTAssertThrowsError(try makePlan(
            width: width, height: 40000, spans: [box],
            extents: [Extent(minY: 1100, maxY: 1200, maxX: width)]
        )) { error in
            guard case let ExportPDFCaptureError.oversizeCaptureArea(captureWidth, height) = error
            else { return XCTFail("Expected per-box capture-area refusal, got \(error)") }
            XCTAssertEqual(captureWidth, width + ExportPDFPagePlanner.widePageSlack, accuracy: 0.5)
            XCTAssertEqual(height, box.height, accuracy: 0.5)
        }
    }

    func testRandomizedSeededPaginationContracts() throws {
        for offset in 0 ..< 500 {
            let seed = 0x20E0_0000 + offset
            var state = UInt64(seed)
            func next(_ upperBound: Int) -> Int {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int((state >> 33) % UInt64(upperBound))
            }
            let aspect: CGFloat? = next(2) == 0 ? nil : 1.29
            let widthChoices: [CGFloat] = aspect == nil
                ? [20000, 50000]
                : [2000, 20000, 50000]
            let firstWidth = widthChoices[next(widthChoices.count)]
            let secondWidth = firstWidth + (next(2) == 0 ? 8000 : 30000)
            let firstCapture = ExportPDFPagePlanner.captureWidth(
                for: firstWidth, contentWidth: secondWidth
            )
            let secondCapture = ExportPDFPagePlanner.captureWidth(
                for: secondWidth, contentWidth: secondWidth
            )
            let firstHard = min(
                ExportPDFPagePlanner.maximumSide,
                ExportPDFPagePlanner.captureAreaBudget / firstCapture
            )
            let secondHard = min(
                ExportPDFPagePlanner.maximumSide,
                ExportPDFPagePlanner.captureAreaBudget / secondCapture
            )
            let firstSoft = min(firstHard, firstCapture * (aspect ?? 1))
            let secondSoft = min(secondHard, secondCapture * (aspect ?? 1))
            let leading = CGFloat(next(80))
            let gap = CGFloat(next(100) + 8)
            let firstHeight = max(20, firstSoft - gap + CGFloat(next(3) - 1))
            let secondHeight = max(20, secondSoft - gap + CGFloat(next(3) - 1))
            let prose = Span(minY: 0, maxY: 40)
            let first = Span(minY: 100 + leading, maxY: 100 + leading + firstHeight)
            let second = Span(
                minY: first.maxY + gap, maxY: first.maxY + gap + secondHeight
            )
            let spans = [prose, first, second]
            let extents = [
                Extent(minY: first.minY, maxY: first.maxY, maxX: firstWidth),
                Extent(minY: second.minY, maxY: second.maxY, maxX: secondWidth),
            ]
            let tail = CGFloat(next(500))
            let inset: CGFloat = 24
            let end = second.maxY + tail
            let stale = CGFloat(next(4000))
            let height = end + inset + stale
            do {
                let plan = try makePlan(
                    width: secondWidth, height: height, spans: spans,
                    extents: extents, aspect: aspect,
                    paintedBottom: end, bottomInset: inset
                )
                guard assertSeededPlanInvariants(
                    plan, width: secondWidth, height: height,
                    spans: spans, aspect: aspect, end: end,
                    bottomInset: inset, seed: seed
                ) else { return }
                assertDistinctRunPages(plan, first: first, second: second, seed: seed)
            } catch {
                XCTFail("seed \(seed): unexpected planner error \(error)")
                return
            }
        }
    }

    private func assertSeededPlanInvariants(
        _ plan: ExportPDFPagePlanner.Plan,
        width: CGFloat,
        height: CGFloat,
        spans: [Span],
        aspect: CGFloat?,
        end: CGFloat,
        bottomInset: CGFloat,
        seed: Int
    ) -> Bool {
        let epsilon: CGFloat = 0.5
        let size = CGSize(width: width, height: height)
        let lastSpanMax = spans.map(\.maxY).max() ?? 0
        let plannedEnd = min(height, max(end, lastSpanMax))
        var failures: [String] = []
        if plan.pages.isEmpty {
            failures.append("has no pages")
        }
        var previousBottom: CGFloat = 0
        for page in plan.pages {
            let rect = page.rect
            if rect.minX != 0 {
                failures.append("page has nonzero x")
            }
            if rect.width < 800 - 0.001
                || rect.width > size.width + ExportPDFPagePlanner.widePageSlack + 0.001
            {
                failures.append("page width \(rect.width) is out of bounds")
            }
            if rect.minY < previousBottom - 0.001 {
                failures.append("pages overlap at \(rect.minY)")
            }
            if rect.minY > previousBottom + epsilon, spans.contains(where: {
                $0.minY < rect.minY - epsilon && $0.maxY > previousBottom + epsilon
            }) {
                failures.append("uncovered strip contains a span")
            }
            let intersectsSpan = spans.contains {
                $0.minY < rect.maxY - epsilon && $0.maxY > rect.minY + epsilon
            }
            let isTail = rect.minY >= lastSpanMax - epsilon
                && rect.maxY <= plannedEnd + epsilon
            if !intersectsSpan, !isTail {
                failures.append("page \(rect) has no content")
            }
            let scale = ExportPDFPagePlanner.pageScale(width: rect.width)
            if abs(page.scale - scale) > 0.0001 {
                failures.append("page scale \(page.scale) does not match \(scale)")
            }
            let hard = min(
                ExportPDFPagePlanner.maximumSide,
                ExportPDFPagePlanner.captureAreaBudget / max(rect.width, 1)
            )
            if rect.height > hard + 0.001 {
                failures.append("page height \(rect.height) exceeds hard budget \(hard)")
            }
            if let aspect {
                let soft = min(hard, rect.width * aspect)
                if rect.height > soft + epsilon, rect.maxY < plannedEnd - epsilon {
                    let overageStart = rect.minY + soft
                    let spanExtendsPastSoft = spans.contains {
                        $0.minY <= overageStart + epsilon && $0.maxY > overageStart + epsilon
                    }
                    let overageIsWhitespace = !spans.contains {
                        $0.minY < rect.maxY - epsilon && $0.maxY > overageStart + epsilon
                    }
                    if !spanExtendsPastSoft, !overageIsWhitespace {
                        failures.append("page exceeds soft budget without an extending span")
                    }
                }
            }
            previousBottom = rect.maxY
        }
        if abs(previousBottom - plannedEnd) > 0.001 {
            failures.append("last page ends at \(previousBottom), not painted end \(plannedEnd)")
        }
        let staleHeight = max(0, height - plannedEnd - bottomInset)
        let baselineHard = min(
            ExportPDFPagePlanner.maximumSide,
            ExportPDFPagePlanner.captureAreaBudget / 800
        )
        let baselineSoft = aspect.map { min(baselineHard, 800 * $0) } ?? baselineHard
        let expectedDropped = staleHeight > 1
            ? Int(ceil(staleHeight / baselineSoft))
            : 0
        if plan.droppedTrailingBlankPages != expectedDropped {
            failures.append(
                "stale-height counter \(plan.droppedTrailingBlankPages) != \(expectedDropped)"
            )
        }
        XCTAssertTrue(
            failures.isEmpty,
            "seed \(seed): \(failures.joined(separator: "; ")); "
                + "spans=\(spans), pages=\(plan.pages.map(\.rect))"
        )
        return failures.isEmpty
    }

    private func assertDistinctRunPages(
        _ plan: ExportPDFPagePlanner.Plan,
        first: Span,
        second: Span,
        seed: Int
    ) {
        guard let firstPage = plan.pages.first(where: { intersects($0.rect, first) }),
              let secondPage = plan.pages.first(where: { intersects($0.rect, second) })
        else {
            return XCTFail("seed \(seed): a wide run has no page")
        }
        XCTAssertFalse(
            intersects(firstPage.rect, second),
            "seed \(seed): whitespace-separated runs shared a page \(firstPage.rect)"
        )
        XCTAssertNotEqual(
            firstPage.rect.width, secondPage.rect.width,
            "seed \(seed): disjoint runs lost their distinct widths"
        )
    }

    private func makePlan(
        width: CGFloat,
        height: CGFloat,
        spans: [Span],
        extents: [Extent] = [],
        aspect: CGFloat? = nil,
        paintedBottom: CGFloat? = nil,
        bottomInset: CGFloat = 0
    ) throws -> ExportPDFPagePlanner.Plan {
        try ExportPDFPagePlanner.plan(
            contentSize: CGSize(width: width, height: height),
            baselineWidth: 800, unsplittable: spans,
            widthExtents: extents, targetAspect: aspect,
            paintedBottom: paintedBottom, bottomInset: bottomInset
        )
    }

    private func intersects(_ rect: CGRect, _ span: Span) -> Bool {
        span.minY < rect.maxY - 0.5 && span.maxY > rect.minY + 0.5
    }
}
