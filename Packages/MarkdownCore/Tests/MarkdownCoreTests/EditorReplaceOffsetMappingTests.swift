import Foundation
@testable import MarkdownCore
import XCTest

final class EditorReplaceOffsetMappingTests: XCTestCase {
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
