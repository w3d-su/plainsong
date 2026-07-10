@testable import MarkdownCore
import XCTest

final class TextSearchUnicodeAndSnippetTests: XCTestCase {
    // MARK: - CJK, emoji, combining marks

    func testCJKEmojiAndCombiningMarksUseExactUTF16Ranges() {
        let text = "前言 café 👨‍👩‍👧 尾"
        let nfdCafe = "cafe\u{0301}"
        let mixed = "pre \(nfdCafe) 中文 👋 post"

        let cafeMatches = TextSearchEngine.matches(
            in: mixed,
            query: TextSearchQuery(pattern: nfdCafe, caseSensitivity: .sensitive),
            limit: 5
        )
        XCTAssertEqual(cafeMatches.count, 1)
        let cafe = cafeMatches[0]
        let expectedCafeRange = (mixed as NSString).range(of: nfdCafe)
        XCTAssertEqual(cafe.range, expectedCafeRange)
        XCTAssertEqual((mixed as NSString).substring(with: cafe.range), nfdCafe)
        XCTAssertEqual(
            (cafe.preview as NSString).substring(with: cafe.previewMatchRange),
            nfdCafe
        )

        let cjkMatches = TextSearchEngine.matches(
            in: mixed,
            query: TextSearchQuery(pattern: "中文", caseSensitivity: .sensitive),
            limit: 5
        )
        XCTAssertEqual(cjkMatches.count, 1)
        XCTAssertEqual(cjkMatches[0].range, (mixed as NSString).range(of: "中文"))
        XCTAssertEqual(cjkMatches[0].range.length, 2)

        let emojiMatches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "👨‍👩‍👧", caseSensitivity: .sensitive),
            limit: 5
        )
        XCTAssertEqual(emojiMatches.count, 1)
        let family = "👨‍👩‍👧"
        XCTAssertEqual(emojiMatches[0].range, (text as NSString).range(of: family))
        XCTAssertEqual(emojiMatches[0].range.length, (family as NSString).length)
        XCTAssertEqual(
            (emojiMatches[0].preview as NSString).substring(with: emojiMatches[0].previewMatchRange),
            family
        )
    }

    // MARK: - Line endings and line numbers

    func testLFCRLFEmptyLinesAndNoTrailingNewlineLineNumbers() {
        let lf = "a\n\nneedle\nb"
        let lfMatches = TextSearchEngine.matches(
            in: lf,
            query: TextSearchQuery(pattern: "needle", caseSensitivity: .sensitive),
            limit: 5
        )
        XCTAssertEqual(lfMatches.count, 1)
        XCTAssertEqual(lfMatches[0].line, 3)
        XCTAssertEqual(lfMatches[0].range, (lf as NSString).range(of: "needle"))

        let crlf = "a\r\n\r\nneedle\r\nb"
        let crlfMatches = TextSearchEngine.matches(
            in: crlf,
            query: TextSearchQuery(pattern: "needle", caseSensitivity: .sensitive),
            limit: 5
        )
        XCTAssertEqual(crlfMatches.count, 1)
        XCTAssertEqual(crlfMatches[0].line, 3)
        XCTAssertEqual(crlfMatches[0].range, (crlf as NSString).range(of: "needle"))

        let ends = "first\nmiddle\nlast-target"
        let first = TextSearchEngine.matches(
            in: ends,
            query: TextSearchQuery(pattern: "first", caseSensitivity: .sensitive),
            limit: 5
        )
        XCTAssertEqual(first[0].line, 1)

        let last = TextSearchEngine.matches(
            in: ends,
            query: TextSearchQuery(pattern: "last-target", caseSensitivity: .sensitive),
            limit: 5
        )
        XCTAssertEqual(last[0].line, 3)

        let emptyBetween = "x\n\ny"
        let yMatch = TextSearchEngine.matches(
            in: emptyBetween,
            query: TextSearchQuery(pattern: "y", caseSensitivity: .sensitive),
            limit: 5
        )
        XCTAssertEqual(yMatch[0].line, 3)
    }

    // MARK: - Snippet truncation

    func testLeadingAndTrailingSnippetTruncationPreservesMatchHighlight() {
        let leftPad = String(repeating: "L", count: 80)
        let rightPad = String(repeating: "R", count: 80)
        let text = leftPad + "MATCH" + rightPad

        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "MATCH", caseSensitivity: .sensitive),
            limit: 1,
            previewContextGraphemes: 5
        )

        XCTAssertEqual(matches.count, 1)
        let match = matches[0]
        XCTAssertTrue(match.preview.hasPrefix(TextSearchEngine.previewEllipsis))
        XCTAssertTrue(match.preview.hasSuffix(TextSearchEngine.previewEllipsis))
        XCTAssertEqual(
            (match.preview as NSString).substring(with: match.previewMatchRange),
            "MATCH"
        )
        XCTAssertEqual(match.preview, "…LLLLLMATCHRRRRR…")

        let leadingOnly = String(repeating: "A", count: 50) + "HIT"
        let leadingMatches = TextSearchEngine.matches(
            in: leadingOnly,
            query: TextSearchQuery(pattern: "HIT", caseSensitivity: .sensitive),
            limit: 1,
            previewContextGraphemes: 3
        )
        XCTAssertEqual(leadingMatches[0].preview, "…AAAHIT")
        XCTAssertEqual(
            (leadingMatches[0].preview as NSString).substring(with: leadingMatches[0].previewMatchRange),
            "HIT"
        )

        let trailingOnly = "HIT" + String(repeating: "B", count: 50)
        let trailingMatches = TextSearchEngine.matches(
            in: trailingOnly,
            query: TextSearchQuery(pattern: "HIT", caseSensitivity: .sensitive),
            limit: 1,
            previewContextGraphemes: 3
        )
        XCTAssertEqual(trailingMatches[0].preview, "HITBBB…")
        XCTAssertEqual(trailingMatches[0].previewMatchRange, NSRange(location: 0, length: 3))
    }

    func testSnippetCutsAtGraphemeBoundariesForEmojiContext() {
        let family = "👨‍👩‍👧"
        let text = String(repeating: family, count: 10) + "X" + String(repeating: family, count: 10)
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "X", caseSensitivity: .sensitive),
            limit: 1,
            previewContextGraphemes: 2
        )

        XCTAssertEqual(matches.count, 1)
        let match = matches[0]
        XCTAssertTrue(match.preview.hasPrefix(TextSearchEngine.previewEllipsis))
        XCTAssertTrue(match.preview.hasSuffix(TextSearchEngine.previewEllipsis))
        XCTAssertEqual(
            (match.preview as NSString).substring(with: match.previewMatchRange),
            "X"
        )
        let expectedCore = family + family + "X" + family + family
        XCTAssertEqual(match.preview, "…" + expectedCore + "…")
    }

    // MARK: - Sub-grapheme matches keep bounded previews

    func testSubGraphemeEmojiComponentPreviewIsBoundedAndExact() {
        let family = "👨‍👩‍👧"
        // Long line so a full-line fallback would be multi-megabyte-scale in spirit.
        let pad = String(repeating: "Z", count: 20000)
        let text = pad + family + pad
        let context = 3

        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "👩", caseSensitivity: .sensitive),
            limit: 5,
            previewContextGraphemes: context
        )

        XCTAssertEqual(matches.count, 1)
        let match = matches[0]
        XCTAssertEqual(match.range, (text as NSString).range(of: "👩"))
        XCTAssertEqual((text as NSString).substring(with: match.range), "👩")
        XCTAssertEqual(
            (match.preview as NSString).substring(with: match.previewMatchRange),
            "👩"
        )

        // Preview must stay O(context), not O(line). Family ZWJ sequence is one composed unit.
        let maxUTF16 =
            (TextSearchEngine.previewEllipsis as NSString).length * 2
                + context * 2 // left/right ASCII pads
                + (family as NSString).length
                + 8 // small slack
        XCTAssertLessThanOrEqual((match.preview as NSString).length, maxUTF16)
        XCTAssertTrue(match.preview.contains(family))
        // No torn surrogates: every high surrogate is followed by a low surrogate in the preview.
        assertTextSearchHasNoTornSurrogates(match.preview)
    }

    func testSubGraphemeCombiningMarkPreviewIsBoundedAndExact() {
        let nfd = "e\u{0301}" // composed sequence length 2; mark is unit 1
        let pad = String(repeating: "Q", count: 15000)
        let text = pad + nfd + pad
        let context = 4

        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "\u{0301}", caseSensitivity: .sensitive),
            limit: 5,
            previewContextGraphemes: context
        )

        XCTAssertEqual(matches.count, 1)
        let match = matches[0]
        XCTAssertEqual(match.range.length, 1)
        XCTAssertEqual((text as NSString).substring(with: match.range), "\u{0301}")
        XCTAssertEqual(
            (match.preview as NSString).substring(with: match.previewMatchRange),
            "\u{0301}"
        )

        let maxUTF16 =
            (TextSearchEngine.previewEllipsis as NSString).length * 2
                + context * 2
                + (nfd as NSString).length
                + 8
        XCTAssertLessThanOrEqual((match.preview as NSString).length, maxUTF16)
        // Full enclosing grapheme is present in the preview core.
        XCTAssertTrue(match.preview.contains(nfd))
        assertTextSearchHasNoTornSurrogates(match.preview)
    }
}
