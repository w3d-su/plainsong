import Foundation
@testable import MarkdownCore
import XCTest

final class EditorFindSessionTests: XCTestCase {
    func testZeroOneAndManyMatchesHaveWellDefinedOrdinals() {
        let empty = EditorFindSession.search(
            in: "no hits here",
            query: TextSearchQuery(pattern: "zzz")
        )
        XCTAssertEqual(empty.total, 0)
        XCTAssertNil(empty.currentOrdinal)
        XCTAssertNil(empty.currentMatch)
        XCTAssertFalse(empty.isTruncated)

        let singleText = "only one needle here"
        let single = EditorFindSession.search(
            in: singleText,
            query: TextSearchQuery(pattern: "needle")
        )
        XCTAssertEqual(single.total, 1)
        XCTAssertEqual(single.currentOrdinal, 1)
        XCTAssertEqual(single.currentMatch?.range, (singleText as NSString).range(of: "needle"))

        let manyText = "a x b x c x d"
        let many = EditorFindSession.search(
            in: manyText,
            query: TextSearchQuery(pattern: "x")
        )
        XCTAssertEqual(many.total, 3)
        XCTAssertEqual(many.currentOrdinal, 1)
        XCTAssertEqual(many.matches.map(\.range.location), [2, 6, 10])
    }

    func testNextAndPreviousWrapAtBothEnds() {
        let text = "0aa1aa2aa3"
        // matches at 1, 4, 7
        let fromStart = EditorFindSession.search(
            in: text,
            query: TextSearchQuery(pattern: "aa"),
            caretAnchorUTF16: 0
        )
        XCTAssertEqual(fromStart.currentOrdinal, 1)
        XCTAssertEqual(fromStart.currentMatch?.range.location, 1)

        var walking = fromStart
        walking = walking.next()
        XCTAssertEqual(walking.currentOrdinal, 2)
        XCTAssertEqual(walking.currentMatch?.range.location, 4)
        walking = walking.next()
        XCTAssertEqual(walking.currentOrdinal, 3)
        XCTAssertEqual(walking.currentMatch?.range.location, 7)
        walking = walking.next()
        XCTAssertEqual(walking.currentOrdinal, 1, "wrap last → first")
        walking = walking.previous()
        XCTAssertEqual(walking.currentOrdinal, 3, "wrap first → last")
        walking = walking.previous()
        XCTAssertEqual(walking.currentOrdinal, 2)
    }

    func testOrdinalNearestToArbitraryCaretAnchor() {
        let text = "0aa1aa2aa3"
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "aa"),
            limit: EditorFindLimits.engineMatchLimit
        )
        XCTAssertEqual(matches.map(\.range.location), [1, 4, 7])

        XCTAssertEqual(
            EditorFindSession.ordinal(nearestTo: 0, preferring: .next, in: matches),
            1
        )
        XCTAssertEqual(
            EditorFindSession.ordinal(nearestTo: 5, preferring: .next, in: matches),
            3
        )
        XCTAssertEqual(
            EditorFindSession.ordinal(nearestTo: 100, preferring: .next, in: matches),
            1,
            "wrap when past last match"
        )
        XCTAssertEqual(
            EditorFindSession.ordinal(nearestTo: 5, preferring: .previous, in: matches),
            2
        )
        XCTAssertEqual(
            EditorFindSession.ordinal(nearestTo: 0, preferring: .previous, in: matches),
            3,
            "wrap when before first match"
        )

        let fromMid = EditorFindSession.search(
            in: text,
            query: TextSearchQuery(pattern: "aa"),
            caretAnchorUTF16: 5
        )
        XCTAssertEqual(fromMid.currentOrdinal, 3)
        XCTAssertEqual(fromMid.currentMatch?.range.location, 7)
    }

    func testSingleMatchNextPreviousStaysOnOnlyMatch() {
        let session = EditorFindSession.search(
            in: "one needle only",
            query: TextSearchQuery(pattern: "needle")
        )
        XCTAssertEqual(session.currentOrdinal, 1)
        XCTAssertEqual(session.next().currentOrdinal, 1)
        XCTAssertEqual(session.previous().currentOrdinal, 1)
        XCTAssertEqual(session.next().currentMatch?.range, session.currentMatch?.range)
    }

    func testEmptyOversizedAndNewlinePatternsYieldEmptySession() {
        let text = "hello world"
        let emptyPattern = EditorFindSession.search(
            in: text,
            query: TextSearchQuery(pattern: "")
        )
        XCTAssertEqual(emptyPattern.total, 0)
        XCTAssertFalse(emptyPattern.isTruncated)

        let oversized = String(repeating: "a", count: TextSearchEngine.maximumPatternUTF16Length + 1)
        let over = EditorFindSession.search(
            in: text + oversized,
            query: TextSearchQuery(pattern: oversized)
        )
        XCTAssertEqual(over.total, 0)

        let newline = EditorFindSession.search(
            in: "a\nb",
            query: TextSearchQuery(pattern: "a\nb")
        )
        XCTAssertEqual(newline.total, 0)
    }

    func testTruncationAtCeilingAndOverflow() throws {
        XCTAssertEqual(EditorFindLimits.retainedMatchCeiling, 10000)
        XCTAssertEqual(EditorFindLimits.engineMatchLimit, 10001)

        let exactText = String(repeating: "x", count: 10000)
        let exact = EditorFindSession.search(
            in: exactText,
            query: TextSearchQuery(pattern: "x")
        )
        XCTAssertEqual(exact.total, 10000)
        XCTAssertFalse(exact.isTruncated)

        let overflowText = String(repeating: "x", count: 10001)
        let truncated = EditorFindSession.search(
            in: overflowText,
            query: TextSearchQuery(pattern: "x")
        )
        XCTAssertEqual(truncated.total, 10000)
        XCTAssertTrue(truncated.isTruncated)
        XCTAssertEqual(truncated.matches.count, 10000)

        // Wrap only within the retained list
        var walk = truncated
        let start = try XCTUnwrap(walk.currentOrdinal)
        for _ in 0 ..< 10000 {
            walk = walk.next()
        }
        XCTAssertEqual(walk.currentOrdinal, start)
    }

    func testEngineResultsCeilingPlusOneDropsOverflow() {
        let matches = (0 ..< 10001).map { index in
            TextSearchMatch(
                range: NSRange(location: index, length: 1),
                line: 1,
                preview: "x",
                previewMatchRange: NSRange(location: 0, length: 1)
            )
        }
        let session = EditorFindSession(
            engineResults: matches,
            query: TextSearchQuery(pattern: "x")
        )
        XCTAssertTrue(session.isTruncated)
        XCTAssertEqual(session.total, 10000)
        XCTAssertEqual(session.matches.last?.range.location, 9999)

        let under = EditorFindSession(
            engineResults: Array(matches.prefix(50)),
            query: TextSearchQuery(pattern: "x")
        )
        XCTAssertFalse(under.isTruncated)
        XCTAssertEqual(under.total, 50)
    }

    func testWithCaretAnchorReResolvesOrdinalWithoutRematching() {
        let text = "aa bb aa bb aa"
        let session = EditorFindSession.search(
            in: text,
            query: TextSearchQuery(pattern: "aa"),
            caretAnchorUTF16: 0
        )
        XCTAssertEqual(session.currentOrdinal, 1)
        let moved = session.withCaretAnchor(12)
        XCTAssertEqual(moved.matches, session.matches)
        XCTAssertEqual(moved.isTruncated, session.isTruncated)
        XCTAssertEqual(moved.currentOrdinal, 3)
        XCTAssertEqual(moved.currentMatch?.range.location, 12)
    }
}
