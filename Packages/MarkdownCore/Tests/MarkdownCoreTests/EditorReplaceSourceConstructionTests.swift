import Foundation
@testable import MarkdownCore
import XCTest

final class EditorReplaceSourceConstructionTests: XCTestCase {
    func testB1SlicePreservesUnicodeGapsAndUntouchedOuterSource() throws {
        let source = "前😀 cat / e\u{0301} cat 尾"
        let session = EditorFindSession.search(in: source, query: TextSearchQuery(pattern: "cat"))
        for replacement in ["kitten", "", "🧪", "$1\\n"] {
            let plan = try EditorReplacePlanner.planBatch(
                session: session, source: source, replacement: replacement
            ).get()
            let enclosing = try XCTUnwrap(plan.enclosingRange)
            XCTAssertEqual(enclosing.location, 4)
            let local = try XCTUnwrap(EditorReplaceSourceConstruction.replacedSlice(
                source, enclosing: enclosing, ranges: plan.differingRanges, replacement: replacement
            ))
            XCTAssertTrue(ExactSourceText.matches(local, "\(replacement) / e\u{0301} \(replacement)"))
            let final = (source as NSString).replacingCharacters(in: enclosing, with: local)
            XCTAssertTrue(ExactSourceText.matches(final, "前😀 \(replacement) / e\u{0301} \(replacement) 尾"))
            XCTAssertEqual((final as NSString).length, plan.projectedUTF16Length)
        }
    }

    func testSliceSupportsPaddingAdjacentMatchesAndEmptyRanges() {
        XCTAssertEqual(EditorReplaceSourceConstruction.replacedSlice(
            "!abab?", enclosing: NSRange(location: 1, length: 4),
            ranges: [NSRange(location: 1, length: 2), NSRange(location: 3, length: 2)],
            replacement: "X"
        ), "XX")
        XCTAssertEqual(EditorReplaceSourceConstruction.replacedSlice(
            "!xcaty?", enclosing: NSRange(location: 1, length: 5),
            ranges: [NSRange(location: 2, length: 3)], replacement: "Q"
        ), "xQy")
        XCTAssertEqual(EditorReplaceSourceConstruction.replacedSlice(
            "!😀?", enclosing: NSRange(location: 1, length: 2), ranges: [], replacement: "X"
        ), "😀")
        XCTAssertEqual(EditorReplaceSourceConstruction.replacedSlice(
            "ab", enclosing: NSRange(location: 1, length: 0), ranges: [], replacement: "X"
        ), "")
        XCTAssertEqual(EditorReplaceSourceConstruction.replacedSlice(
            "ab", enclosing: NSRange(location: 1, length: 0),
            ranges: [NSRange(location: 1, length: 0)], replacement: "X"
        ), "X")
    }

    func testSliceRejectsInvalidEnclosingAndEscapingRanges() {
        for enclosing in [
            NSRange(location: -1, length: 1), NSRange(location: 0, length: -1),
            NSRange(location: 2, length: 3), NSRange(location: Int.max, length: 1),
        ] {
            XCTAssertNil(EditorReplaceSourceConstruction.replacedSlice(
                "abcd", enclosing: enclosing, ranges: [], replacement: "X"
            ))
        }
        for range in [
            NSRange(location: 0, length: 1), NSRange(location: 2, length: 2),
            NSRange(location: 4, length: 0), NSRange(location: Int.max, length: 1),
        ] {
            XCTAssertNil(EditorReplaceSourceConstruction.replacedSlice(
                "abcd", enclosing: NSRange(location: 1, length: 2), ranges: [range], replacement: "X"
            ))
        }
    }

    func testEveryConsumerRejectsMalformedRangeListsIncludingUnvisitedSuffixes() {
        let first = NSRange(location: 1, length: 2)
        let invalidLists = [
            [NSRange(location: -1, length: 1)],
            [NSRange(location: 0, length: -1)],
            [first, NSRange(location: 2, length: 1)], // overlap
            [first, NSRange(location: 0, length: 1)], // descending
            [first, NSRange(location: Int.max, length: 1)], // overflowing suffix
            [first, NSRange(location: 4, length: -1)],
        ]
        for ranges in invalidLists {
            XCTAssertNil(EditorReplaceSourceConstruction.enclosingRange(of: ranges))
            XCTAssertNil(EditorReplaceSourceConstruction.projectedUTF16Length(
                sourceLength: 4, ranges: ranges, replacementUTF16Length: 1
            ))
            XCTAssertNil(EditorReplaceSourceConstruction.replacedSource("abcd", ranges: ranges, replacement: "X"))
            XCTAssertNil(EditorReplaceSourceConstruction.replacedSlice(
                "abcd", enclosing: NSRange(location: 0, length: 4), ranges: ranges, replacement: "X"
            ))
            // Both offsets would previously return before examining the bad suffix.
            for offset in [0, 2] {
                XCTAssertNil(EditorReplaceSourceConstruction.mapUTF16Offset(
                    offset, through: ranges, replacementUTF16Length: 1
                ))
            }
        }
    }

    func testOptionalLengthBoundAndEmptyListContracts() {
        let outside = [NSRange(location: 4, length: 1)]
        XCTAssertEqual(EditorReplaceSourceConstruction.enclosingRange(of: outside), outside[0])
        XCTAssertEqual(
            EditorReplaceSourceConstruction.mapUTF16Offset(0, through: outside, replacementUTF16Length: 1),
            0
        )
        XCTAssertNil(EditorReplaceSourceConstruction.projectedUTF16Length(
            sourceLength: 4, ranges: outside, replacementUTF16Length: 1
        ))
        XCTAssertNil(EditorReplaceSourceConstruction.replacedSource("abcd", ranges: outside, replacement: "X"))
        XCTAssertNil(EditorReplaceSourceConstruction.projectedUTF16Length(
            sourceLength: -1, ranges: [], replacementUTF16Length: 1
        ))
        XCTAssertNil(EditorReplaceSourceConstruction.enclosingRange(of: []))
        XCTAssertEqual(EditorReplaceSourceConstruction.projectedUTF16Length(
            sourceLength: 4, ranges: [], replacementUTF16Length: 1
        ), 4)
        XCTAssertEqual(EditorReplaceSourceConstruction.replacedSource("abcd", ranges: [], replacement: "X"), "abcd")
        XCTAssertEqual(EditorReplaceSourceConstruction.mapUTF16Offset(2, through: [], replacementUTF16Length: 1), 2)
    }
}
