@testable import MarkdownCore
import XCTest

final class TextSearchWholeWordTests: XCTestCase {
    func testWholeWordVersusSubstring() {
        let text = "cat catalog scatter cat"

        let substring = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "cat", caseSensitivity: .sensitive),
            limit: 20
        )
        XCTAssertEqual(substring.count, 4)

        let wholeWord = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "cat", caseSensitivity: .sensitive, wholeWord: true),
            limit: 20
        )
        XCTAssertEqual(wholeWord.count, 2)
        XCTAssertEqual(wholeWord[0].range, NSRange(location: 0, length: 3))
        XCTAssertEqual(wholeWord[1].range, NSRange(location: 20, length: 3))
    }

    func testWholeWordTreatsLettersNumbersAndUnderscoreAsWordCharacters() {
        let text = "foo_bar foo bar bar2 文字 文字学"

        let foo = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "foo", caseSensitivity: .sensitive, wholeWord: true),
            limit: 10
        )
        XCTAssertEqual(foo.map(\.range), [NSRange(location: 8, length: 3)])

        let bar = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "bar", caseSensitivity: .sensitive, wholeWord: true),
            limit: 10
        )
        XCTAssertEqual(bar.count, 1)
        XCTAssertEqual((text as NSString).substring(with: bar[0].range), "bar")

        let cjk = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "文字", caseSensitivity: .sensitive, wholeWord: true),
            limit: 10
        )
        XCTAssertEqual(cjk.count, 1)
    }

    func testWholeWordBoundaryWithAllUnicodeNumberCategories() {
        let text = "item item٢ item item３ itemⅧ item½ item"
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "item", caseSensitivity: .sensitive, wholeWord: true),
            limit: 20
        )

        XCTAssertEqual(matches.count, 3)
        for match in matches {
            XCTAssertEqual((text as NSString).substring(with: match.range), "item")
        }
    }

    func testDecoratedUnderscoreRemainsAWordCharacter() {
        for decoratedUnderscore in ["_\u{FE0F}", "_\u{0301}"] {
            let text = "foo\(decoratedUnderscore) \(decoratedUnderscore)foo foo"
            let matches = TextSearchEngine.matches(
                in: text,
                query: TextSearchQuery(pattern: "foo", caseSensitivity: .sensitive, wholeWord: true),
                limit: 10
            )

            XCTAssertEqual(matches.count, 1)
            XCTAssertEqual(matches[0].range.location, (text as NSString).range(of: "foo", options: .backwards).location)
        }
    }

    func testDecomposedLetterPreventsWholeWordMatch() {
        let text = "e\u{0301}foo foo"
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "foo", caseSensitivity: .sensitive, wholeWord: true),
            limit: 10
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].range.location, (text as NSString).range(of: "foo", options: .backwards).location)
    }

    func testSubGraphemeMatchIsNotWholeWord() {
        let family = "👨‍👩‍👧"
        let matches = TextSearchEngine.matches(
            in: " \(family) ",
            query: TextSearchQuery(pattern: "👩", caseSensitivity: .sensitive, wholeWord: true),
            limit: 5
        )
        XCTAssertTrue(matches.isEmpty)
    }

    func testUnicodeWholeWordPreservesFoundationMatchSemantics() {
        let cases = [
            FoundationSemanticsCase(text: " ß ", pattern: "SS", sensitivity: .insensitive, expected: "ß"),
            FoundationSemanticsCase(text: " SS ", pattern: "ß", sensitivity: .insensitive, expected: "SS"),
            FoundationSemanticsCase(text: " ﬃ ", pattern: "ffi", sensitivity: .insensitive, expected: "ﬃ"),
            FoundationSemanticsCase(text: " ς ", pattern: "Σ", sensitivity: .insensitive, expected: "ς"),
            FoundationSemanticsCase(text: " İ ", pattern: "i\u{0307}", sensitivity: .insensitive, expected: "İ"),
            FoundationSemanticsCase(text: " ① ", pattern: "1", sensitivity: .insensitive, expected: "①"),
            FoundationSemanticsCase(text: " １ ", pattern: "1", sensitivity: .insensitive, expected: "１"),
            FoundationSemanticsCase(text: " 2🏽 ", pattern: "2", sensitivity: .insensitive, expected: "2🏽"),
            FoundationSemanticsCase(text: " IⅧ ", pattern: "İ", sensitivity: .insensitive, expected: "IⅧ"),
            FoundationSemanticsCase(text: " SЖ ", pattern: "ß", sensitivity: .insensitive, expected: "SЖ"),
            FoundationSemanticsCase(
                text: " 🇨🇦🏽 ",
                pattern: "🇨🇦🏽",
                sensitivity: .sensitive,
                expected: "🇨🇦🏽"
            ),
            FoundationSemanticsCase(
                text: " café ",
                pattern: "cafe\u{0301}",
                sensitivity: .sensitive,
                expected: "café"
            ),
        ]

        for testCase in cases {
            let matches = TextSearchEngine.matches(
                in: testCase.text,
                query: TextSearchQuery(
                    pattern: testCase.pattern,
                    caseSensitivity: testCase.sensitivity,
                    wholeWord: true
                ),
                limit: 10
            )

            XCTAssertEqual(matches.count, 1, "pattern: \(testCase.pattern)")
            if let match = matches.first {
                XCTAssertEqual(
                    (testCase.text as NSString).substring(with: match.range),
                    testCase.expected,
                    "pattern: \(testCase.pattern)"
                )
            }
        }
    }

    func testUnicodeWholeWordRejectsPartialCaseFoldExpansion() {
        for (text, pattern) in [(" ß ", "S"), (" ßa ", "Sa"), (" aß ", "aS")] {
            let matches = TextSearchEngine.matches(
                in: text,
                query: TextSearchQuery(pattern: pattern, caseSensitivity: .insensitive, wholeWord: true),
                limit: 10
            )

            XCTAssertTrue(matches.isEmpty, "text: \(text), pattern: \(pattern)")
        }
    }

    func testUnicodeWholeWordUsesFoundationCollation() {
        let capital = "\u{10400}"
        let lowercase = "\u{10428}"
        let text = " \(capital) "
        let expected = (text as NSString).range(of: lowercase, options: [.caseInsensitive])
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: lowercase, caseSensitivity: .insensitive, wholeWord: true),
            limit: 10
        )

        if expected.location == NSNotFound {
            XCTAssertTrue(matches.isEmpty)
        } else {
            XCTAssertEqual(matches.map(\.range), [expected])
        }
    }

    func testUnicodeWholeWordContinuesPastInsideWordCandidates() {
        let text = "éé é"
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "é", caseSensitivity: .sensitive, wholeWord: true),
            limit: 10
        )

        XCTAssertEqual(matches.map(\.range), [(text as NSString).range(of: "é", options: .backwards)])
    }

    func testWholeWordUsesFoundationComposedBoundariesForPrependScalars() {
        let text = "\u{0600}A"
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "A", caseSensitivity: .sensitive, wholeWord: true),
            limit: 10
        )

        XCTAssertEqual(matches.map(\.range), [NSRange(location: 1, length: 1)])
    }

    func testInsensitiveWholeWordMatchesAcrossFoundationIgnoredZWNJ() {
        let text = "क\u{094D}\u{200C}क"
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(
                pattern: "क\u{094D}क",
                caseSensitivity: .insensitive,
                wholeWord: true
            ),
            limit: 10
        )

        XCTAssertEqual(matches.map(\.range), [NSRange(location: 0, length: 4)])
    }

    func testInsensitiveWholeWordMatchesDigitWithFoundationIgnoredCombiningMark() {
        let text = " 1\u{0301} "
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "1", caseSensitivity: .insensitive, wholeWord: true),
            limit: 10
        )

        XCTAssertEqual(matches.map(\.range), [NSRange(location: 1, length: 2)])
    }

    func testFoundationContextRejectsMatchImmediatelyBeforeZWNJ() {
        let text = " σ\u{200C} "
        for sensitivity in [TextSearchCaseSensitivity.sensitive, .insensitive] {
            let matches = TextSearchEngine.matches(
                in: text,
                query: TextSearchQuery(pattern: "σ", caseSensitivity: sensitivity, wholeWord: true),
                limit: 10
            )

            XCTAssertTrue(matches.isEmpty, "sensitivity: \(sensitivity)")
        }
    }

    func testSensitiveWholeWordUsesFoundationContextForTrailingIgnorables() {
        let text = " 1\u{200C} "
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(
                pattern: "1\u{200D}",
                caseSensitivity: .sensitive,
                wholeWord: true
            ),
            limit: 10
        )

        XCTAssertEqual(matches.map(\.range), [NSRange(location: 1, length: 2)])
    }

    func testIgnoredScalarBoundaryAlternativesPreserveFoundationRanges() {
        let zwnj = "\u{200C}"
        let text = zwnj + "क"
        let exact = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: text, caseSensitivity: .insensitive, wholeWord: true),
            limit: 10
        )
        let withoutLeadingIgnorable = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "क", caseSensitivity: .insensitive, wholeWord: true),
            limit: 10
        )

        XCTAssertEqual(exact.map(\.range), [NSRange(location: 0, length: 2)])
        XCTAssertEqual(withoutLeadingIgnorable.map(\.range), [NSRange(location: 1, length: 1)])
    }

    func testPatternContainingOnlyIgnoredScalarsFallsBackToFoundation() {
        let text = " \u{200C} "
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "\u{200C}", caseSensitivity: .insensitive, wholeWord: true),
            limit: 10
        )

        let expected = (text as NSString).range(of: "\u{200C}", options: [.caseInsensitive])
        if expected.location == NSNotFound {
            XCTAssertTrue(matches.isEmpty)
        } else {
            XCTAssertEqual(matches.map(\.range), [expected])
        }
    }
}

final class TextSearchWholeWordLineTests: XCTestCase {
    func testAcceptedMatchAfterRejectedCandidatesHasCorrectLine() {
        let text = "xx\nxxx\n x "
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "x", caseSensitivity: .sensitive, wholeWord: true),
            limit: 10
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].line, 3)
        XCTAssertEqual(matches[0].range, (text as NSString).range(of: " x ").shifted(by: 1))
    }
}

private struct FoundationSemanticsCase {
    let text: String
    let pattern: String
    let sensitivity: TextSearchCaseSensitivity
    let expected: String
}

private extension NSRange {
    func shifted(by offset: Int) -> NSRange {
        NSRange(location: location + offset, length: length - offset * 2)
    }
}
