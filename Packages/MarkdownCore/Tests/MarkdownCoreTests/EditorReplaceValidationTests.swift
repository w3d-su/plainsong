import Foundation
@testable import MarkdownCore
import XCTest

final class EditorReplaceValidationTests: XCTestCase {
    func testEmptyReplacementIsValid() {
        XCTAssertEqual(EditorReplacePlanning.validateReplacement(""), .valid)
    }

    func testLiteralDollarAndEscapeSequencesAreValid() {
        XCTAssertEqual(EditorReplacePlanning.validateReplacement("$1"), .valid)
        XCTAssertEqual(EditorReplacePlanning.validateReplacement("\\1"), .valid)
        XCTAssertEqual(EditorReplacePlanning.validateReplacement("\\n"), .valid)
    }

    func testActualNewlinesAreInvalid() {
        XCTAssertEqual(EditorReplacePlanning.validateReplacement("a\nb"), .containsNewline)
        XCTAssertEqual(EditorReplacePlanning.validateReplacement("a\rb"), .containsNewline)
        XCTAssertEqual(EditorReplacePlanning.validateReplacement("a\u{2028}b"), .containsNewline)
        XCTAssertEqual(EditorReplacePlanning.validateReplacement("a\u{2029}b"), .containsNewline)
    }

    func testTwoHundredFiftySixCodeUnitsAreValidAndTwoFiftySevenAreNot() {
        let limit = String(repeating: "z", count: 256)
        let over = limit + "z"
        XCTAssertEqual((limit as NSString).length, 256)
        XCTAssertEqual(EditorReplacePlanning.validateReplacement(limit), .valid)
        XCTAssertEqual(
            EditorReplacePlanning.validateReplacement(over),
            .exceedsMaximumUTF16Length
        )
        let emojiLimit = String(repeating: "🙂", count: 128)
        XCTAssertEqual((emojiLimit as NSString).length, 256)
        XCTAssertEqual(EditorReplacePlanning.validateReplacement(emojiLimit), .valid)
        XCTAssertEqual(
            EditorReplacePlanning.validateReplacement(emojiLimit + "🙂"),
            .exceedsMaximumUTF16Length
        )
    }

    func testLiteralIdentityUsesUTF16NotCanonicalStringEquality() {
        let nfc = "é"
        let nfd = "e\u{0301}"
        XCTAssertEqual(nfc, nfd)
        XCTAssertFalse(ExactSourceText.matches(nfc, nfd))
        XCTAssertFalse(EditorReplacePlanning.isLiteralIdentical(
            source: nfc,
            range: NSRange(location: 0, length: (nfc as NSString).length),
            replacement: nfd
        ))
        XCTAssertTrue(EditorReplacePlanning.isLiteralIdentical(
            source: nfc,
            range: NSRange(location: 0, length: (nfc as NSString).length),
            replacement: nfc
        ))
    }

    func testProjectedLengthOverflowAndGrowthCap() {
        let tooMany = Array(
            repeating: NSRange(location: 0, length: 0),
            count: EditorFindLimits.retainedMatchCeiling
        )
        // 10,000 * 256 = 2,560,000 growth from empty inserts into an empty source.
        XCTAssertEqual(
            EditorReplaceSourceConstruction.projectedUTF16Length(
                sourceLength: 0,
                ranges: tooMany,
                replacementUTF16Length: 256
            ),
            2_560_000
        )
        XCTAssertNil(EditorReplaceSourceConstruction.projectedUTF16Length(
            sourceLength: 0,
            ranges: tooMany,
            replacementUTF16Length: 257
        ))
        XCTAssertNil(EditorReplaceSourceConstruction.projectedUTF16Length(
            sourceLength: 1,
            ranges: [NSRange(location: 0, length: 2)],
            replacementUTF16Length: 1
        ))
        XCTAssertNil(EditorReplaceSourceConstruction.projectedUTF16Length(
            sourceLength: 0,
            ranges: [
                NSRange(location: 0, length: 0),
                NSRange(location: 0, length: 0),
            ],
            replacementUTF16Length: Int.max
        ))
    }

    func testMalformedRangesFailClosedWithoutEndOverflow() {
        let overflow = NSRange(location: Int.max, length: 1)
        XCTAssertNil(EditorReplacePlanning.slice("x", range: overflow))
        XCTAssertNil(EditorReplaceSourceConstruction.enclosingRange(of: [overflow]))
        XCTAssertNil(EditorReplaceSourceConstruction.projectedUTF16Length(
            sourceLength: 1,
            ranges: [overflow],
            replacementUTF16Length: 1
        ))
        XCTAssertNil(EditorReplaceSourceConstruction.replacedSource(
            "x",
            ranges: [overflow],
            replacement: "y"
        ))
        XCTAssertNil(EditorReplaceSourceConstruction.mapUTF16Offset(
            0,
            through: [overflow],
            replacementUTF16Length: 1
        ))
    }
}
