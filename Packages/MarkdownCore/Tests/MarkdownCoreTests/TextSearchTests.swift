@testable import MarkdownCore
import XCTest

final class TextSearchTests: XCTestCase {
    // MARK: - Basic matching

    func testBasicLiteralMatchesAcrossLinesAndMultipleOnOneLine() {
        let text = """
        alpha beta
        gamma alpha
        alpha alpha tail
        """
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "alpha", caseSensitivity: .sensitive),
            limit: 20
        )

        XCTAssertEqual(matches.count, 4)
        XCTAssertEqual(matches.map(\.line), [1, 2, 3, 3])
        XCTAssertEqual(matches[0].range, NSRange(location: 0, length: 5))
        XCTAssertEqual(matches[1].range, NSRange(location: 17, length: 5))
        XCTAssertLessThanOrEqual(
            matches[2].range.location + matches[2].range.length,
            matches[3].range.location
        )
        XCTAssertEqual((text as NSString).substring(with: matches[2].range), "alpha")
        XCTAssertEqual((text as NSString).substring(with: matches[3].range), "alpha")
    }

    func testNonOverlappingLeftToRightOrder() {
        let text = "aaaa"
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "aa", caseSensitivity: .sensitive),
            limit: 10
        )

        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].range, NSRange(location: 0, length: 2))
        XCTAssertEqual(matches[1].range, NSRange(location: 2, length: 2))
    }

    // MARK: - Case modes

    func testSmartCaseIsInsensitiveWhenPatternIsAllLowercase() {
        let text = "Hello HELLO hello"
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "hello", caseSensitivity: .smart),
            limit: 10
        )

        XCTAssertEqual(matches.count, 3)
    }

    func testSmartCaseIsSensitiveWhenPatternContainsUppercase() {
        let text = "Hello HELLO hello"
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "Hello", caseSensitivity: .smart),
            limit: 10
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].range, NSRange(location: 0, length: 5))
    }

    func testSmartCaseWithNonASCIILetters() {
        // Lowercase Greek → smart insensitive.
        let greek = "αλφά ΑΛΦΆ αλφά"
        let insensitive = TextSearchEngine.matches(
            in: greek,
            query: TextSearchQuery(pattern: "αλφά", caseSensitivity: .smart),
            limit: 10
        )
        XCTAssertEqual(insensitive.count, 3)

        // Cased uppercase in the query → smart sensitive.
        let sensitive = TextSearchEngine.matches(
            in: greek,
            query: TextSearchQuery(pattern: "ΑΛΦΆ", caseSensitivity: .smart),
            limit: 10
        )
        XCTAssertEqual(sensitive.count, 1)
        XCTAssertEqual((greek as NSString).substring(with: sensitive[0].range), "ΑΛΦΆ")
    }

    func testSmartCaseTreatsUnicodeTitlecaseAsSensitive() {
        let text = "Ǆ ǅ ǆ"
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "ǅ", caseSensitivity: .smart),
            limit: 10
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual((text as NSString).substring(with: matches[0].range), "ǅ")
    }

    func testSmartCaseDetectsUppercaseScalarsWithoutLowercaseMappings() {
        let cases = [
            (query: "ℂat", text: "ℂat ℂAT"),
            (query: "𝐀bc", text: "𝐀bc 𝐀BC"),
            (query: "Ⅷitem", text: "Ⅷitem ⅧITEM"),
        ]

        for testCase in cases {
            let matches = TextSearchEngine.matches(
                in: testCase.text,
                query: TextSearchQuery(pattern: testCase.query, caseSensitivity: .smart),
                limit: 10
            )
            XCTAssertEqual(matches.count, 1, "query \(testCase.query)")
            XCTAssertEqual((testCase.text as NSString).substring(with: matches[0].range), testCase.query)
        }
    }

    func testExplicitSensitiveAndInsensitiveModes() {
        let text = "Swift swift SWIFT"

        let sensitive = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "swift", caseSensitivity: .sensitive),
            limit: 10
        )
        XCTAssertEqual(sensitive.count, 1)
        XCTAssertEqual(sensitive[0].range, NSRange(location: 6, length: 5))

        let insensitive = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "swift", caseSensitivity: .insensitive),
            limit: 10
        )
        XCTAssertEqual(insensitive.count, 3)
    }

    // MARK: - Unicode folding / normalization

    func testCaseInsensitiveSharpSFoldingAndContractions() {
        // Query longer (UTF-16) than the folded source match.
        let strasse = TextSearchEngine.matches(
            in: "straße",
            query: TextSearchQuery(pattern: "STRASSE", caseSensitivity: .insensitive),
            limit: 5
        )
        XCTAssertEqual(strasse.count, 1)
        XCTAssertEqual(strasse[0].range, NSRange(location: 0, length: 6))
        XCTAssertEqual(("straße" as NSString).substring(with: strasse[0].range), "straße")
        XCTAssertEqual(
            (strasse[0].preview as NSString).substring(with: strasse[0].previewMatchRange),
            "straße"
        )

        // Two non-overlapping contractions: each ß folds to SS.
        let double = TextSearchEngine.matches(
            in: "ßß",
            query: TextSearchQuery(pattern: "SS", caseSensitivity: .insensitive),
            limit: 5
        )
        XCTAssertEqual(double.count, 2)
        XCTAssertEqual(double[0].range, NSRange(location: 0, length: 1))
        XCTAssertEqual(double[1].range, NSRange(location: 1, length: 1))

        // Same folding at the end of a longer source.
        let atEnd = TextSearchEngine.matches(
            in: "prefix-xxß",
            query: TextSearchQuery(pattern: "SS", caseSensitivity: .insensitive),
            limit: 5
        )
        XCTAssertEqual(atEnd.count, 1)
        XCTAssertEqual(atEnd[0].range, NSRange(location: 9, length: 1))
        XCTAssertEqual(("prefix-xxß" as NSString).substring(with: atEnd[0].range), "ß")
    }

    func testSensitiveCanonicalEquivalenceNFDQueryMatchesNFCSource() {
        let nfc = "café" // é is typically NFC U+00E9
        let nfdPattern = "cafe\u{0301}" // e + combining acute
        let matches = TextSearchEngine.matches(
            in: nfc,
            query: TextSearchQuery(pattern: nfdPattern, caseSensitivity: .sensitive),
            limit: 5
        )
        XCTAssertEqual(matches.count, 1)
        // Foundation returns the NFC source range (not the NFD query length).
        XCTAssertEqual(matches[0].range, (nfc as NSString).range(of: nfdPattern))
        XCTAssertEqual((nfc as NSString).substring(with: matches[0].range), "café")
        XCTAssertEqual(
            (matches[0].preview as NSString).substring(with: matches[0].previewMatchRange),
            "café"
        )

        let atEnd = TextSearchEngine.matches(
            in: "xx" + nfc,
            query: TextSearchQuery(pattern: nfdPattern, caseSensitivity: .sensitive),
            limit: 5
        )
        XCTAssertEqual(atEnd.count, 1)
        XCTAssertEqual(atEnd[0].range.location, 2)
    }

    // MARK: - Empty / invalid queries and limits

    func testEmptyPatternNewlinePatternAndNonPositiveLimitsReturnNoMatches() {
        let text = "hello\nworld"

        XCTAssertTrue(
            TextSearchEngine.matches(in: "", query: TextSearchQuery(pattern: "hello"), limit: 10).isEmpty
        )

        XCTAssertTrue(
            TextSearchEngine.matches(in: text, query: TextSearchQuery(pattern: ""), limit: 10).isEmpty
        )
        XCTAssertTrue(
            TextSearchEngine.matches(in: text, query: TextSearchQuery(pattern: "hel\nlo"), limit: 10).isEmpty
        )
        XCTAssertTrue(
            TextSearchEngine.matches(in: text, query: TextSearchQuery(pattern: "hello\rworld"), limit: 10)
                .isEmpty
        )
        for newline in ["\r\n", "\u{0085}", "\u{2028}", "\u{2029}"] {
            XCTAssertTrue(
                TextSearchEngine.matches(
                    in: text,
                    query: TextSearchQuery(pattern: "hello\(newline)world"),
                    limit: 10
                ).isEmpty
            )
        }
        let overlongPattern = String(
            repeating: "x",
            count: TextSearchEngine.maximumPatternUTF16Length + 1
        )
        XCTAssertTrue(
            TextSearchEngine.matches(
                in: text,
                query: TextSearchQuery(pattern: overlongPattern),
                limit: 10
            ).isEmpty
        )
        XCTAssertTrue(
            TextSearchEngine.matches(in: text, query: TextSearchQuery(pattern: "hello"), limit: 0).isEmpty
        )
        XCTAssertTrue(
            TextSearchEngine.matches(in: text, query: TextSearchQuery(pattern: "hello"), limit: -3).isEmpty
        )
    }

    func testLimitCapsResultCount() {
        let text = "ab ab ab ab ab"
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "ab", caseSensitivity: .sensitive),
            limit: 3
        )
        XCTAssertEqual(matches.count, 3)
    }

    // MARK: - Literal regex metacharacters

    func testRegexMetacharactersAreLiteral() {
        let text = "a+b* and .* and (x) and [0-9] and foo$bar^"
        let patterns = ["a+b*", ".*", "(x)", "[0-9]", "foo$bar^"]

        for pattern in patterns {
            let matches = TextSearchEngine.matches(
                in: text,
                query: TextSearchQuery(pattern: pattern, caseSensitivity: .sensitive),
                limit: 5
            )
            XCTAssertEqual(matches.count, 1, "pattern \(pattern) should match literally once")
            XCTAssertEqual((text as NSString).substring(with: matches[0].range), pattern)
        }
    }

    // MARK: - Value semantics

    func testQueryAndMatchAreEquatableAndSendable() {
        let query = TextSearchQuery(pattern: "x", caseSensitivity: .smart, wholeWord: true)
        XCTAssertEqual(query, TextSearchQuery(pattern: "x", caseSensitivity: .smart, wholeWord: true))
        assertSendable(query)

        let match = TextSearchMatch(
            range: NSRange(location: 1, length: 2),
            line: 3,
            preview: "ab",
            previewMatchRange: NSRange(location: 0, length: 2)
        )
        XCTAssertEqual(
            match,
            TextSearchMatch(
                range: NSRange(location: 1, length: 2),
                line: 3,
                preview: "ab",
                previewMatchRange: NSRange(location: 0, length: 2)
            )
        )
        assertSendable(match)
        assertSendable(TextSearchCaseSensitivity.smart)
    }
}

private func assertSendable(_ value: some Sendable) {
    _ = value
}
