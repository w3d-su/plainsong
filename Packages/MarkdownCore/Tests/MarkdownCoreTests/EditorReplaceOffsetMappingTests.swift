import Foundation
@testable import MarkdownCore
import XCTest

final class EditorReplaceOffsetMappingTests: XCTestCase {
    func testInteriorCaretIncludesTwoPrecedingUnequalLengthEdits() throws {
        let source = "cat cat dog cat"
        let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "cat"))
        // The third match is [12, 15); offset 13 lies inside it.
        for (replacement, expected) in [("kitten", 24), ("x", 9), ("", 6), ("🧪", 12)] {
            let plan = try EditorReplacePlanner.planBatch(
                session: session, source: source, replacement: replacement
            ).get()
            let post = try XCTUnwrap(EditorReplaceSourceConstruction.replacedSource(
                source, ranges: plan.differingRanges, replacement: replacement
            ))
            let result = EditorReplaceContinuationPlanning.afterBatch(
                plan: plan, preWriteCurrentMatch: nil, preWriteCaretUTF16: 13, postWriteSource: post
            )
            XCTAssertEqual(EditorReplaceSourceConstruction.mapUTF16Offset(
                13, through: plan.differingRanges, replacementUTF16Length: replacement.utf16.count
            ), expected)
            XCTAssertEqual(result.resumeUTF16, expected)
            XCTAssertEqual(result.session.caretAnchorUTF16, expected)
            XCTAssertEqual(result.collapsedSelection, NSRange(location: expected, length: 0))
        }
    }

    func testAdjacentMatchStartMapsToSecondReplacementEnd() {
        let session = EditorFindSession.search(in: "abab", query: TextSearchQuery(pattern: "ab"))
        XCTAssertEqual(session.matches.map(\.range), [
            NSRange(location: 0, length: 2), NSRange(location: 2, length: 2),
        ])
        for (replacementLength, expected) in [(0, 0), (1, 2), (3, 6)] {
            XCTAssertEqual(EditorReplaceSourceConstruction.mapUTF16Offset(
                2, through: session.matches.map(\.range), replacementUTF16Length: replacementLength
            ), expected)
        }
    }

    func testCurrentMatchEndDoesNotAdvanceThroughAnAdjacentFollowingEdit() throws {
        for source in ["abab", "abAB"] {
            let session = EditorFindSession.search(
                in: source, query: TextSearchQuery(pattern: "ab", caseSensitivity: .insensitive)
            )
            // Also cover a literal-identical current match whose adjacent successor
            // is the only differing range in the batch.
            for replacement in ["XYZ", "ab"] {
                let plan = try EditorReplacePlanner.planBatch(
                    session: session, source: source, replacement: replacement
                ).get()
                if plan.isNoOp { continue }
                let post = try XCTUnwrap(EditorReplaceSourceConstruction.replacedSource(
                    source, ranges: plan.differingRanges, replacement: replacement
                ))
                let result = EditorReplaceContinuationPlanning.afterBatch(
                    plan: plan, preWriteCurrentMatch: session.currentMatch,
                    preWriteCaretUTF16: 0, postWriteSource: post
                )
                XCTAssertEqual(result.resumeUTF16, replacement.utf16.count)
                XCTAssertEqual(result.session.caretAnchorUTF16, result.resumeUTF16)
                XCTAssertEqual(result.collapsedSelection, NSRange(location: replacement.utf16.count, length: 0))
            }
        }
    }

    func testBatchContinuationClampsAllCaretOutputsTogether() throws {
        let session = EditorFindSession.search(in: "cat", query: TextSearchQuery(pattern: "cat"))
        let plan = try EditorReplacePlanner.planBatch(
            session: session, source: "cat", replacement: "x"
        ).get()
        for (caret, expected) in [(-1, 0), (99, 1), (Int.max, 1)] {
            let result = EditorReplaceContinuationPlanning.afterBatch(
                plan: plan, preWriteCurrentMatch: nil, preWriteCaretUTF16: caret, postWriteSource: "x"
            )
            XCTAssertEqual(result.resumeUTF16, expected)
            XCTAssertEqual(result.session.caretAnchorUTF16, result.resumeUTF16)
            XCTAssertEqual(result.collapsedSelection, NSRange(location: expected, length: 0))
            XCTAssertNil(result.session.currentOrdinal)
        }
        let empty = EditorReplaceContinuationPlanning.afterBatch(
            plan: plan, preWriteCurrentMatch: session.currentMatch,
            preWriteCaretUTF16: 0, postWriteSource: ""
        )
        XCTAssertEqual(empty.resumeUTF16, 0)
        XCTAssertEqual(empty.session.caretAnchorUTF16, empty.resumeUTF16)
        XCTAssertEqual(empty.collapsedSelection, NSRange(location: 0, length: 0))
    }

    func testBatchContinuationMapsCaretInsideLaterMatchThroughEarlierEdits() throws {
        let source = "one two one tail"
        for (replacement, expectedEnd) in [("Z", 7), ("longer", 17), ("", 5), ("🧪", 9)] {
            let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "one"))
                .withUnresolvedCurrent(caretAnchorUTF16: 9)
            let plan = try EditorReplacePlanner.planBatch(session: session, source: source, replacement: replacement)
                .get()
            let post = try XCTUnwrap(EditorReplaceSourceConstruction.replacedSource(
                source, ranges: plan.differingRanges, replacement: replacement
            ))
            XCTAssertEqual(post, "\(replacement) two \(replacement) tail")
            let result = EditorReplaceContinuationPlanning.afterBatch(
                plan: plan, preWriteCurrentMatch: nil, preWriteCaretUTF16: 9, postWriteSource: post
            )
            XCTAssertEqual(result.collapsedSelection, NSRange(location: expectedEnd, length: 0))
            XCTAssertEqual(result.session.caretAnchorUTF16, expectedEnd)
        }
    }

    func testInteriorMappingRetainsOverflowChecksAndBoundarySemantics() {
        let ranges = [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3)]
        for offset in 8 ... 11 {
            XCTAssertEqual(EditorReplaceSourceConstruction.mapUTF16Offset(
                offset, through: ranges, replacementUTF16Length: 1
            ), 7)
        }
        XCTAssertNil(EditorReplaceSourceConstruction.mapUTF16Offset(
            9, through: ranges, replacementUTF16Length: Int.max
        ))
        XCTAssertEqual(EditorReplaceSourceConstruction.mapUTF16Offset(
            7, through: ranges, replacementUTF16Length: 1
        ), 5)
    }
}
