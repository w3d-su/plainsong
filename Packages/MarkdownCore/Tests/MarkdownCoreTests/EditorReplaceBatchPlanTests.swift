import Foundation
@testable import MarkdownCore
import XCTest

final class EditorReplaceBatchPlanTests: XCTestCase {
    func testTruncatedSessionRefusesReplaceAll() {
        let source = String(repeating: "x", count: 10001)
        let session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: "x")
        )
        XCTAssertTrue(session.isTruncated)
        XCTAssertEqual(
            EditorReplacePlanner.planBatch(
                session: session,
                source: source,
                replacement: "y"
            ),
            .failure(.truncatedSession)
        )
    }

    func testExactTenThousandIsEligible() {
        let source = String(repeating: "x", count: 10000)
        let session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: "x")
        )
        XCTAssertFalse(session.isTruncated)
        let plan = try? EditorReplacePlanner.planBatch(
            session: session,
            source: source,
            replacement: "y"
        ).get()
        XCTAssertEqual(plan?.totalCount, 10000)
        XCTAssertEqual(plan?.changedCount, 10000)
        XCTAssertEqual(plan?.isNoOp, false)
    }

    func testAllIdenticalIsNoOpAndMixedFiltersLiteralUTF16() {
        let source = "one two one"
        let session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: "one")
        )
        let noOp = try? EditorReplacePlanner.planBatch(
            session: session,
            source: source,
            replacement: "one"
        ).get()
        XCTAssertEqual(noOp?.isNoOp, true)
        XCTAssertEqual(noOp?.changedCount, 0)
        XCTAssertEqual(noOp?.totalCount, 2)
        XCTAssertNil(noOp?.enclosingRange)

        let mixedSource = "é e\u{0301} é"
        let mixedSession = EditorFindSession.search(
            in: mixedSource,
            query: TextSearchQuery(pattern: "é", caseSensitivity: .insensitive)
        )
        let mixed = try? EditorReplacePlanner.planBatch(
            session: mixedSession,
            source: mixedSource,
            replacement: "é"
        ).get()
        XCTAssertEqual(mixed?.totalCount, mixedSession.total)
        XCTAssertGreaterThan(mixed?.changedCount ?? 0, 0)
        XCTAssertLessThan(mixed?.changedCount ?? 0, mixed?.totalCount ?? 0)
    }

    func testReplacedSourceUsesDifferingRangesOnly() {
        let source = "aa ba aa"
        let session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: "aa")
        )
        let plan = try? EditorReplacePlanner.planBatch(
            session: session,
            source: source,
            replacement: "aa"
        ).get()
        XCTAssertEqual(plan?.isNoOp, true)
        let rebuilt = EditorReplaceSourceConstruction.replacedSource(
            source,
            ranges: plan?.differingRanges ?? [NSRange(location: 0, length: 1)],
            replacement: "aa"
        )
        XCTAssertEqual(rebuilt, source)
    }

    func testEmptySessionRefusesBatch() {
        let session = EditorFindSession.search(
            in: "hello",
            query: TextSearchQuery(pattern: "zzz")
        )
        XCTAssertEqual(
            EditorReplacePlanner.planBatch(
                session: session,
                source: "hello",
                replacement: "X"
            ),
            .failure(.emptySession)
        )
    }

    func testCancellationCadenceIsIndependentFromVisibleProgressCoalescing() {
        XCTAssertFalse(EditorReplaceSourceConstruction.shouldCheckCancellation(
            plannedMatchesSinceLastCheck: 63,
            copiedUTF16SinceLastCheck: 65535
        ))
        XCTAssertTrue(EditorReplaceSourceConstruction.shouldCheckCancellation(
            plannedMatchesSinceLastCheck: 64,
            copiedUTF16SinceLastCheck: 0
        ))
        XCTAssertTrue(EditorReplaceSourceConstruction.shouldCheckCancellation(
            plannedMatchesSinceLastCheck: 0,
            copiedUTF16SinceLastCheck: 65536
        ))

        let milestones = EditorReplaceSourceConstruction.progressUpdateMilestones(
            totalMatchCount: 10000
        )
        XCTAssertEqual(milestones.count, EditorReplaceLimits.maximumProgressUpdates)
        XCTAssertEqual(milestones.first, 100)
        XCTAssertEqual(milestones.last, 10000)
        XCTAssertEqual(milestones, milestones.sorted())
        XCTAssertEqual(
            EditorReplaceSourceConstruction.progressUpdateMilestones(totalMatchCount: 3),
            [1, 2, 3]
        )
    }
}
