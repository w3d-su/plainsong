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

    func testProgressCheckpointsHonorBothChunkLimits() {
        let byMatch = EditorReplaceSourceConstruction.progressCheckpoints(
            rangeCount: 250,
            replacementUTF16Length: 256
        )
        XCTAssertEqual(byMatch, [64, 128, 192, 250])

        let byUTF16 = EditorReplaceSourceConstruction.progressCheckpoints(
            rangeCount: 200,
            replacementUTF16Length: EditorReplaceLimits.progressUTF16Chunk
        )
        XCTAssertEqual(byUTF16.count, EditorReplaceLimits.maximumProgressUpdates)
        XCTAssertEqual(byUTF16.first, 1)
        XCTAssertEqual(byUTF16.last, 200)
        XCTAssertEqual(byUTF16[98], 99)
    }
}
