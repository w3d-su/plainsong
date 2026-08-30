import Foundation
@testable import MarkdownCore
import XCTest

final class EditorReplaceContinuationTests: XCTestCase {
    func testPlanBindsTheQueryUsedForPostWriteRescan() throws {
        let source = "a b a"
        let session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: "a", caseSensitivity: .sensitive)
        )
        let plan = try EditorReplacePlanner.planOneMatch(
            session: session,
            source: source,
            replacement: "z"
        ).get()
        let continued = EditorReplaceContinuationPlanning.afterOneReplace(
            plan: plan,
            postWriteSource: "z b a"
        )

        XCTAssertEqual(plan.query, session.query)
        XCTAssertEqual(continued.session.query, session.query)
        XCTAssertEqual(continued.session.currentMatch?.range.location, 4)
    }

    func testSourceChangingOneReplaceRescansAndSkipsInsertedSpan() throws {
        let source = "a b a"
        let session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: "a")
        )
        let plan = try EditorReplacePlanner.planOneMatch(
            session: session,
            source: source,
            replacement: "aa"
        ).get()
        let post = try XCTUnwrap(EditorReplaceSourceConstruction.replacedSource(
            source,
            ranges: [plan.match.range],
            replacement: plan.replacement
        ))
        XCTAssertEqual(post, "aa b a")
        let continued = EditorReplaceContinuationPlanning.afterOneReplace(
            plan: plan,
            postWriteSource: post
        )
        XCTAssertEqual(plan.resumeUTF16, 2)
        XCTAssertEqual(continued.session.currentMatch?.range.location, 5)
        XCTAssertEqual(continued.session.total, 3)
        XCTAssertNotEqual(continued.session.currentMatch?.range.location, 0)
        XCTAssertNotEqual(continued.session.currentMatch?.range.location, 1)
    }

    func testNoLaterMatchLeavesCurrentNilUntilExplicitNext() throws {
        let source = "a b a"
        var session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: "a")
        )
        session = session.next()
        let plan = try EditorReplacePlanner.planOneMatch(
            session: session,
            source: source,
            replacement: "z"
        ).get()
        let post = try XCTUnwrap(EditorReplaceSourceConstruction.replacedSource(
            source,
            ranges: [plan.match.range],
            replacement: plan.replacement
        ))
        let continued = EditorReplaceContinuationPlanning.afterOneReplace(
            plan: plan,
            postWriteSource: post
        )
        XCTAssertEqual(post, "a b z")
        XCTAssertNil(continued.session.currentOrdinal)
        XCTAssertEqual(continued.session.total, 1)
        XCTAssertEqual(continued.session.next().currentOrdinal, 1)
    }

    func testReplaceAllRescansOnceAndClearsCurrent() throws {
        let source = "one two one"
        let session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: "one")
        )
        let plan = try EditorReplacePlanner.planBatch(
            session: session,
            source: source,
            replacement: "aa"
        ).get()
        let post = try XCTUnwrap(EditorReplaceSourceConstruction.replacedSource(
            source,
            ranges: plan.differingRanges,
            replacement: plan.replacement
        ))
        XCTAssertEqual(post, "aa two aa")
        let continued = EditorReplaceContinuationPlanning.afterBatch(
            plan: plan,
            preWriteCurrentMatch: session.currentMatch,
            preWriteCaretUTF16: session.caretAnchorUTF16,
            postWriteSource: post
        )
        XCTAssertNil(continued.session.currentOrdinal)
        XCTAssertEqual(continued.session.query, plan.query)
        XCTAssertEqual(continued.session.total, 0)
        XCTAssertEqual(continued.collapsedSelection.location, 2)
        XCTAssertEqual(continued.session.caretAnchorUTF16, 2)
    }

    func testReplaceAllMapsCaretWhenThereWasNoCurrentMatch() throws {
        let source = "one two one"
        let session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: "one")
        ).withUnresolvedCurrent(caretAnchorUTF16: 4)
        let plan = try EditorReplacePlanner.planBatch(
            session: session,
            source: source,
            replacement: "ONE"
        ).get()
        let continued = EditorReplaceContinuationPlanning.afterBatch(
            plan: plan,
            preWriteCurrentMatch: nil,
            preWriteCaretUTF16: 4,
            postWriteSource: "ONE two ONE"
        )
        XCTAssertNil(continued.session.currentOrdinal)
        XCTAssertEqual(continued.collapsedSelection.location, 4)
    }

    func testTruncatedSingleReplaceContinuesOnlyInTheRetainedPrefix() throws {
        let source = String(repeating: "x", count: 20000)
        var session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: "x")
        )
        XCTAssertTrue(session.isTruncated)
        session = session.withCurrentOrdinal(10000, caretAnchorUTF16: 9999)
        let plan = try EditorReplacePlanner.planOneMatch(
            session: session,
            source: source,
            replacement: "y"
        ).get()
        XCTAssertEqual(plan.match.range.location, 9999)
        let post = try XCTUnwrap(EditorReplaceSourceConstruction.replacedSource(
            source,
            ranges: [plan.match.range],
            replacement: plan.replacement
        ))
        let continued = EditorReplaceContinuationPlanning.afterOneReplace(
            plan: plan,
            postWriteSource: post
        )
        XCTAssertTrue(continued.session.isTruncated)
        XCTAssertEqual(continued.session.total, 10000)
        XCTAssertEqual(continued.session.currentMatch?.range.location, 10000)
        XCTAssertLessThan(
            continued.session.matches.last?.range.location ?? 0,
            20000
        )
    }
}
