import Foundation
@testable import MarkdownCore
import XCTest

final class EditorReplaceOneMatchPlanTests: XCTestCase {
    func testPlanUsesSessionCurrentMatchNotASecondScan() {
        let source = "one two one"
        let session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: "one", caseSensitivity: .sensitive)
        )
        let second = session.next()
        let plan = try? EditorReplacePlanner.planOneMatch(
            session: second,
            source: source,
            replacement: "ONE"
        ).get()
        XCTAssertEqual(plan?.match.range.location, 8)
        XCTAssertEqual(plan?.query, session.query)
        XCTAssertEqual(plan?.resumeUTF16, 11)
        XCTAssertFalse(plan?.isLiteralIdentical == true)
    }

    func testMatchLengthComesFromTheEngineRange() {
        let composed = "café"
        let decomposed = "cafe\u{0301}"
        let source = "\(composed) \(decomposed)"
        let session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: composed, caseSensitivity: .insensitive)
        )
        XCTAssertGreaterThanOrEqual(session.total, 2)
        let lengths = Set(session.matches.map(\.range.length))
        XCTAssertTrue(lengths.count > 1 || session.matches.contains {
            $0.range.length != (composed as NSString).length
        })
        let plan = try? EditorReplacePlanner.planOneMatch(
            session: session,
            source: source,
            replacement: "X"
        ).get()
        XCTAssertEqual(plan?.match.range.length, session.currentMatch?.range.length)
        XCTAssertNotEqual(plan?.resumeUTF16, session.currentMatch.map { $0.range.location + 4 })
        XCTAssertEqual(
            plan?.resumeUTF16,
            (session.currentMatch.map(\.range.location) ?? 0) + 1
        )
    }

    func testLiteralIdenticalSkipsMutationAndAdvancesToNextStart() throws {
        let source = "one two one"
        let session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: "one")
        )
        let plan = try? EditorReplacePlanner.planOneMatch(
            session: session,
            source: source,
            replacement: "one"
        ).get()
        XCTAssertEqual(plan?.isLiteralIdentical, true)
        XCTAssertEqual(plan?.resumeUTF16, 3)
        let continued = try EditorReplaceContinuationPlanning.afterLiteralIdentical(
            plan: XCTUnwrap(plan),
            session: session
        )
        XCTAssertEqual(continued.session.currentOrdinal, 2)
        XCTAssertEqual(continued.session.currentMatch?.range.location, 8)
        XCTAssertEqual(continued.session.matches, session.matches)
    }

    func testLiteralIdenticalAtLastMatchLeavesCurrentNilWithoutWrap() throws {
        let source = "one two one"
        var session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: "one")
        )
        session = session.next()
        let plan = try? EditorReplacePlanner.planOneMatch(
            session: session,
            source: source,
            replacement: "one"
        ).get()
        let continued = try EditorReplaceContinuationPlanning.afterLiteralIdentical(
            plan: XCTUnwrap(plan),
            session: session
        )
        XCTAssertNil(continued.session.currentOrdinal)
        XCTAssertEqual(continued.session.total, 2)
        XCTAssertEqual(continued.resumeUTF16, 11)
        XCTAssertEqual(continued.session.next().currentOrdinal, 1)
    }

    func testEmptyAndUnresolvedSessionsRefuseOneMatch() {
        let empty = EditorFindSession.search(
            in: "hello",
            query: TextSearchQuery(pattern: "zzz")
        )
        XCTAssertEqual(
            EditorReplacePlanner.planOneMatch(
                session: empty,
                source: "hello",
                replacement: "X"
            ),
            .failure(.emptySession)
        )
        let populated = EditorFindSession.search(
            in: "one one",
            query: TextSearchQuery(pattern: "one")
        ).withUnresolvedCurrent(caretAnchorUTF16: 0)
        XCTAssertNil(populated.currentOrdinal)
        XCTAssertEqual(
            EditorReplacePlanner.planOneMatch(
                session: populated,
                source: "one one",
                replacement: "X"
            ),
            .failure(.noCurrentMatch)
        )
    }

    func testInvalidReplacementRefusesOneMatch() {
        let session = EditorFindSession.search(
            in: "one",
            query: TextSearchQuery(pattern: "one")
        )
        XCTAssertEqual(
            EditorReplacePlanner.planOneMatch(
                session: session,
                source: "one",
                replacement: "a\nb"
            ),
            .failure(.invalidReplacement(.containsNewline))
        )
    }

    func testPlannerDoesNotRescanTheProvidedSource() throws {
        let session = EditorFindSession.search(
            in: "one two one",
            query: TextSearchQuery(pattern: "one")
        )
        let foreign = "xxx yyy xxx"
        let plan = try EditorReplacePlanner.planOneMatch(
            session: session,
            source: foreign,
            replacement: "ONE"
        ).get()
        XCTAssertEqual(plan.match.range, session.currentMatch?.range)
        XCTAssertEqual(plan.match.range.location, 0)
        let post = try XCTUnwrap(EditorReplaceSourceConstruction.replacedSource(
            foreign,
            ranges: [plan.match.range],
            replacement: plan.replacement
        ))
        XCTAssertEqual(post, "ONE yyy xxx")
    }

    func testEmptyReplacementDeletesAndTemplatesStayLiteral() throws {
        let source = "one two one"
        let session = EditorFindSession.search(
            in: source,
            query: TextSearchQuery(pattern: "one")
        )
        let deleted = try EditorReplacePlanner.planOneMatch(
            session: session,
            source: source,
            replacement: ""
        ).get()
        XCTAssertEqual(
            EditorReplaceSourceConstruction.replacedSource(
                source,
                ranges: [deleted.match.range],
                replacement: ""
            ),
            " two one"
        )
        XCTAssertEqual(deleted.resumeUTF16, 0)

        for literal in ["$1", "\\1", "\\n"] {
            let plan = try EditorReplacePlanner.planOneMatch(
                session: session,
                source: source,
                replacement: literal
            ).get()
            XCTAssertEqual(
                EditorReplaceSourceConstruction.replacedSource(
                    source,
                    ranges: [plan.match.range],
                    replacement: literal
                ),
                "\(literal) two one"
            )
        }
    }
}
