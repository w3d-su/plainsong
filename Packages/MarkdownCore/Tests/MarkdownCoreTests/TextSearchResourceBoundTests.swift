@testable import MarkdownCore
import XCTest

final class TextSearchResourceBoundTests: XCTestCase {
    func testOneMegabyteContinuousUnicodeWordSkipsRejectedCandidatesLinearly() {
        let length = 1024 * 1024
        let text = String(repeating: "é", count: length)
        let instrumentation = TextSearchInstrumentation()
        let clock = ContinuousClock()
        let start = clock.now
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "é", caseSensitivity: .sensitive, wholeWord: true),
            limit: 10,
            instrumentation: instrumentation
        )
        let elapsed = start.duration(to: .now)

        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(instrumentation.literalCandidatesExamined, 1)
        XCTAssertLessThanOrEqual(instrumentation.uncachedComposedUTF16UnitsVisited, length + 2)
        assertTextSearchDurationUnderLocally(elapsed, .seconds(3), "1 MiB continuous Unicode word")
    }

    func testMostlyASCIIUnicodeDocumentRestartsSafelyAfterWhitespace() {
        let byteLimit = 1024 * 1024
        let suffix = " 🙂 x"
        let text = String(
            repeating: "x",
            count: byteLimit - suffix.utf8.count
        ) + suffix
        let instrumentation = TextSearchInstrumentation()
        let clock = ContinuousClock()
        let start = clock.now
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "x", caseSensitivity: .sensitive, wholeWord: true),
            limit: 10,
            instrumentation: instrumentation
        )
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(text.utf8.count, byteLimit)
        XCTAssertEqual(matches.map(\.range), [(text as NSString).range(of: "x", options: .backwards)])
        XCTAssertEqual(instrumentation.literalCandidatesExamined, 1)
        XCTAssertLessThanOrEqual(instrumentation.uncachedComposedUTF16UnitsVisited, 64)
        assertTextSearchDurationUnderLocally(elapsed, .seconds(2), "mostly-ASCII Unicode document")
    }

    func testMultilingualWordSkipIsLinear() {
        let alphabet = (0 ..< 65).compactMap { Unicode.Scalar(0x0410 + $0).map(String.init) }
        let text = String(repeating: alphabet.joined(), count: 8192)
        let instrumentation = TextSearchInstrumentation()
        let clock = ContinuousClock()
        let start = clock.now
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: alphabet[0], caseSensitivity: .sensitive, wholeWord: true),
            limit: 10,
            instrumentation: instrumentation
        )
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(alphabet.count, 65)
        XCTAssertGreaterThanOrEqual(text.utf8.count, 1024 * 1024)
        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(instrumentation.literalCandidatesExamined, 1)
        XCTAssertLessThanOrEqual(
            instrumentation.uncachedComposedUTF16UnitsVisited,
            (text as NSString).length + 2
        )
        assertTextSearchDurationUnderLocally(elapsed, .seconds(3), "multilingual word skip")
    }

    func testMaximumLengthUnicodePatternUsesCompactLinearState() {
        let repetitions = 128
        let pattern = String(repeating: "é.", count: repetitions)
        let instrumentation = TextSearchInstrumentation()
        let clock = ContinuousClock()
        let start = clock.now
        let matches = TextSearchEngine.matches(
            in: pattern,
            query: TextSearchQuery(pattern: pattern, caseSensitivity: .sensitive, wholeWord: true),
            limit: 1,
            instrumentation: instrumentation
        )
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(matches.map(\.range), [NSRange(location: 0, length: pattern.utf16.count)])
        XCTAssertEqual(instrumentation.literalCandidatesExamined, 1)
        XCTAssertEqual(pattern.utf16.count, TextSearchEngine.maximumPatternUTF16Length)
        assertTextSearchDurationUnderLocally(elapsed, .seconds(1), "maximum-length Unicode pattern")
    }

    func testDenseMixedASCIIWholeWordSearchSkipsImpossibleCandidates() {
        let byteLimit = 1024 * 1024
        let pattern = String(
            repeating: "x",
            count: TextSearchEngine.maximumPatternUTF16Length
        )
        let scenarios = [
            DenseMixedASCIIScenario(suffix: "\u{200C}", expectsMatch: false, expectedCandidates: 1),
            DenseMixedASCIIScenario(suffix: ".🙂", expectsMatch: false, expectedCandidates: 0),
            DenseMixedASCIIScenario(suffix: "-🙂", expectsMatch: false, expectedCandidates: 0),
            DenseMixedASCIIScenario(suffix: "🙂" + pattern, expectsMatch: true, expectedCandidates: 1),
        ]

        for scenario in scenarios {
            let text = String(
                repeating: "x",
                count: byteLimit - scenario.suffix.utf8.count
            ) + scenario.suffix
            let instrumentation = TextSearchInstrumentation()
            let clock = ContinuousClock()
            let start = clock.now
            let matches = TextSearchEngine.matches(
                in: text,
                query: TextSearchQuery(pattern: pattern, caseSensitivity: .sensitive, wholeWord: true),
                limit: 500,
                instrumentation: instrumentation
            )
            let elapsed = start.duration(to: .now)

            let expected = scenario.expectsMatch
                ? [(text as NSString).range(of: pattern, options: .backwards)]
                : []
            XCTAssertEqual(text.utf8.count, byteLimit)
            XCTAssertEqual(matches.map(\.range), expected, "suffix: \(scenario.suffix)")
            XCTAssertEqual(
                instrumentation.literalCandidatesExamined,
                scenario.expectedCandidates
            )
            assertTextSearchDurationUnderLocally(elapsed, .seconds(2), "dense Foundation fallback")
        }
    }

    func testMixedASCIIEmojiDocumentPrefiltersShortRejectedWords() {
        let byteLimit = 1024 * 1024
        let suffix = "🙂"

        for sensitivity in [TextSearchCaseSensitivity.sensitive, .insensitive] {
            let segment = sensitivity == .sensitive ? "xx " : "xX "
            let available = byteLimit - suffix.utf8.count
            let text = String(repeating: segment, count: available / segment.utf8.count)
                + String(repeating: "x", count: available % segment.utf8.count)
                + suffix
            let instrumentation = TextSearchInstrumentation()
            let clock = ContinuousClock()
            let start = clock.now
            let matches = TextSearchEngine.matches(
                in: text,
                query: TextSearchQuery(pattern: "x", caseSensitivity: sensitivity, wholeWord: true),
                limit: 500,
                instrumentation: instrumentation
            )
            let elapsed = start.duration(to: .now)

            XCTAssertEqual(text.utf8.count, byteLimit)
            XCTAssertTrue(matches.isEmpty)
            XCTAssertEqual(instrumentation.literalCandidatesExamined, 0)
            assertTextSearchDurationUnderLocally(elapsed, .seconds(2), "short-word prefilter")
        }
    }

    func testBoundedFoundationFallbackHandlesLateIgnorableCandidates() {
        let pattern = String(repeating: ".a..", count: 64)
        var text = String(repeating: pattern, count: 3)
        let insertion = text.index(text.startIndex, offsetBy: pattern.count - 1)
        text.insert("\u{200B}", at: insertion)
        let instrumentation = TextSearchInstrumentation()
        let clock = ContinuousClock()
        let start = clock.now
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: pattern, caseSensitivity: .insensitive, wholeWord: true),
            limit: 10,
            instrumentation: instrumentation
        )
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(instrumentation.literalCandidatesExamined, 2)
        XCTAssertEqual(matches[0].range.length, pattern.utf16.count)
        XCTAssertEqual(matches[1].range.length, pattern.utf16.count)
        assertTextSearchDurationUnderLocally(elapsed, .seconds(1), "bounded late-ignorable fallback")
    }

    func testLeadingIgnoredRunUsesFoundationFallback() {
        let ignoredCount = 32000
        let text = String(repeating: "\u{200C}", count: ignoredCount) + "A"
        let instrumentation = TextSearchInstrumentation()
        let clock = ContinuousClock()
        let start = clock.now
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "A", caseSensitivity: .insensitive, wholeWord: true),
            limit: 10,
            instrumentation: instrumentation
        )
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(matches.map(\.range), [NSRange(location: ignoredCount, length: 1)])
        XCTAssertEqual(instrumentation.literalCandidatesExamined, 1)
        assertTextSearchDurationUnderLocally(elapsed, .seconds(1), "leading-ignorable fallback")
    }

    func testOverlongPatternIsRejectedBeforeScannerAllocation() {
        let pattern = String(
            repeating: "é",
            count: TextSearchEngine.maximumPatternUTF16Length + 1
        )
        let instrumentation = TextSearchInstrumentation()
        let matches = TextSearchEngine.matches(
            in: pattern,
            query: TextSearchQuery(pattern: pattern, caseSensitivity: .sensitive, wholeWord: true),
            limit: 1,
            instrumentation: instrumentation
        )

        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(instrumentation.literalCandidatesExamined, 0)
        XCTAssertEqual(instrumentation.uncachedComposedUTF16UnitsVisited, 0)
        XCTAssertEqual(instrumentation.literalSourceUTF16UnitsVisited, 0)
    }
}

private struct DenseMixedASCIIScenario {
    let suffix: String
    let expectsMatch: Bool
    let expectedCandidates: Int
}
