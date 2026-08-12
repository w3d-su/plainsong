import Foundation
@testable import MarkdownCore
import XCTest

final class EditorReplaceContinuationRescanTests: XCTestCase {
    func testWholeWordDestructionComesFromFullRescan() throws {
        let source = "a cat"
        let session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: "cat", wholeWord: true)
        )
        XCTAssertEqual(session.total, 1)
        let plan = try EditorReplacePlanner.planOneMatch(
            session: session,
            source: source,
            replacement: "x"
        ).get()
        let post = try XCTUnwrap(EditorReplaceSourceConstruction.replacedSource(
            source,
            ranges: [plan.match.range],
            replacement: plan.replacement
        ))
        XCTAssertEqual(post, "a x")
        let continued = EditorReplaceContinuationPlanning.afterOneReplace(
            plan: plan,
            query: session.query,
            postWriteSource: post
        )
        XCTAssertEqual(continued.session.total, 0)
        XCTAssertNil(continued.session.currentOrdinal)
    }

    func testWholeWordCreationAfterResumeComesFromFullRescan() throws {
        let source = "cat dog cat"
        let session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: "cat", wholeWord: true)
        )
        let plan = try EditorReplacePlanner.planOneMatch(
            session: session,
            source: source,
            replacement: "cat cat"
        ).get()
        let post = try XCTUnwrap(EditorReplaceSourceConstruction.replacedSource(
            source,
            ranges: [plan.match.range],
            replacement: plan.replacement
        ))
        XCTAssertEqual(post, "cat cat dog cat")
        let continued = EditorReplaceContinuationPlanning.afterOneReplace(
            plan: plan,
            query: session.query,
            postWriteSource: post
        )
        XCTAssertEqual(continued.session.matches.map(\.range.location), [0, 4, 12])
        XCTAssertEqual(plan.resumeUTF16, 7)
        XCTAssertEqual(continued.session.currentMatch?.range.location, 12)
    }

    func testCanonicalEquivalentRemainderComesFromFullRescan() throws {
        let nfc = "é"
        let nfd = "e\u{0301}"
        let source = "\(nfc) \(nfd)"
        let session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: nfc, caseSensitivity: .insensitive)
        )
        XCTAssertEqual(session.total, 2)
        let plan = try EditorReplacePlanner.planOneMatch(
            session: session,
            source: source,
            replacement: "X"
        ).get()
        let post = try XCTUnwrap(EditorReplaceSourceConstruction.replacedSource(
            source,
            ranges: [plan.match.range],
            replacement: plan.replacement
        ))
        let continued = EditorReplaceContinuationPlanning.afterOneReplace(
            plan: plan,
            query: session.query,
            postWriteSource: post
        )
        XCTAssertEqual(continued.session.total, 1)
        XCTAssertEqual(
            continued.session.currentMatch?.range.length,
            (nfd as NSString).length
        )
    }

    func testReplacementCreatedHitsAreCountedAndSkipped() throws {
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
        let continued = EditorReplaceContinuationPlanning.afterOneReplace(
            plan: plan,
            query: session.query,
            postWriteSource: post
        )
        XCTAssertEqual(continued.session.matches.map(\.range.location), [0, 1, 5])
        XCTAssertEqual(continued.session.currentMatch?.range.location, 5)
        XCTAssertEqual(plan.resumeUTF16, 2)
    }

    func testTruncatedReplacementContainingQueryStaysInPrefix() throws {
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
            replacement: "xx"
        ).get()
        XCTAssertEqual(plan.resumeUTF16, 10001)
        let post = try XCTUnwrap(EditorReplaceSourceConstruction.replacedSource(
            source,
            ranges: [plan.match.range],
            replacement: plan.replacement
        ))
        let continued = EditorReplaceContinuationPlanning.afterOneReplace(
            plan: plan,
            query: session.query,
            postWriteSource: post
        )
        XCTAssertTrue(continued.session.isTruncated)
        XCTAssertEqual(continued.session.total, 10000)
        XCTAssertNil(continued.session.currentOrdinal)
        XCTAssertEqual(continued.session.matches.last?.range.location, 9999)
        XCTAssertEqual(continued.session.next().currentOrdinal, 1)
    }
}
