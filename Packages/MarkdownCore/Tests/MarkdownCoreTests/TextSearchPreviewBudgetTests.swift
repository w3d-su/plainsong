@testable import MarkdownCore
import XCTest

final class TextSearchPreviewBudgetTests: XCTestCase {
    func testOversizedSingleGraphemeUsesExactMatchFallback() {
        let left = String(repeating: "👨\u{200D}", count: 1000)
        let right = String(repeating: "\u{200D}👧", count: 1000)
        let giant = left + "👩" + right
        let matches = TextSearchEngine.matches(
            in: giant,
            query: TextSearchQuery(pattern: "👩", caseSensitivity: .sensitive),
            limit: 1,
            previewContextGraphemes: Int.max
        )

        XCTAssertEqual(giant.count, 1)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].preview, "…👩…")
        assertTextSearchMatchesAreValid(matches, in: giant, expected: "👩")
    }

    func testPreviewBudgetPreservesMaximumLengthLiteralMatch() {
        let pattern = String(
            repeating: "M",
            count: TextSearchEngine.maximumPatternUTF16Length
        )
        let text = String(repeating: "L", count: 5000) + pattern + String(repeating: "R", count: 5000)
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: pattern, caseSensitivity: .sensitive),
            limit: 1,
            previewContextGraphemes: Int.max
        )

        XCTAssertEqual(matches.count, 1)
        guard let match = matches.first else {
            return XCTFail("Expected the maximum-length pattern to match")
        }
        let maximumLength =
            (pattern as NSString).length
                + 2 * TextSearchEngine.maximumPreviewContextUTF16PerSide
                + 2
        XCTAssertLessThanOrEqual((match.preview as NSString).length, maximumLength)
        assertTextSearchMatchesAreValid(matches, in: text, expected: pattern)
    }

    func testUnboundedRequestedContextStillUsesTheUTF16Cap() {
        let text = String(repeating: "L", count: 10000) + "X" + String(repeating: "R", count: 10000)
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "X", caseSensitivity: .sensitive),
            limit: 1,
            previewContextGraphemes: Int.max
        )

        let maximumLength = 1 + 2 * TextSearchEngine.maximumPreviewContextUTF16PerSide + 2
        XCTAssertEqual(matches.count, 1)
        XCTAssertLessThanOrEqual((matches[0].preview as NSString).length, maximumLength)
        assertTextSearchMatchesAreValid(matches, in: text, expected: "X")
    }

    func testLargeCRLFDocumentFindsExactMatchOnFinalLine() {
        let lineCount = 60000
        let prefix = Array(repeating: "ordinary markdown line", count: lineCount).joined(separator: "\r\n")
        let text = prefix + "\r\nTARGET"
        let instrumentation = TextSearchInstrumentation()
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "TARGET", caseSensitivity: .sensitive),
            limit: 1,
            instrumentation: instrumentation
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].line, lineCount + 1)
        XCTAssertEqual(matches[0].range, (text as NSString).range(of: "TARGET"))
        XCTAssertLessThanOrEqual(instrumentation.lineUTF16UnitsVisited, (text as NSString).length)
        assertTextSearchMatchesAreValid(matches, in: text, expected: "TARGET")
    }
}
