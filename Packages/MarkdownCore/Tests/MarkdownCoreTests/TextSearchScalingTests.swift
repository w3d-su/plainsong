@testable import MarkdownCore
import XCTest

final class TextSearchScalingTests: XCTestCase {
    func testDistributedMatchesInOneMegabyteLineUseLinearWork() {
        let count = 500
        let token = "hit"
        let segment = String(repeating: "a", count: 2090) + " \(token) "
        let text = String(repeating: segment, count: count)
        let instrumentation = TextSearchInstrumentation()

        let clock = ContinuousClock()
        let start = clock.now
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: token, caseSensitivity: .sensitive),
            limit: count,
            previewContextGraphemes: 2,
            instrumentation: instrumentation
        )
        let elapsed = start.duration(to: .now)

        XCTAssertGreaterThan((text as NSString).length, 1_000_000)
        XCTAssertEqual(matches.count, count)
        XCTAssertEqual(matches.map(\.line), Array(repeating: 1, count: count))
        XCTAssertLessThanOrEqual(instrumentation.lineUTF16UnitsVisited, (text as NSString).length)
        XCTAssertLessThanOrEqual(instrumentation.literalSourceUTF16UnitsVisited, (text as NSString).length)
        XCTAssertEqual(instrumentation.literalCandidatesExamined, count)
        assertTextSearchMatchesAreValid(matches, in: text, expected: token)
        assertTextSearchDurationUnderLocally(elapsed, .seconds(1), "1 MiB dense-line search")
    }

    func testGiantZWJGraphemeAcceptedMatchesAreLinearAndOutputBounded() {
        let componentCount = 2000
        let resultLimit = 500
        let leadingGiant = Array(repeating: "👨", count: componentCount).joined(separator: "\u{200D}")
        let giant = Array(repeating: "👩", count: componentCount).joined(separator: "\u{200D}")
        let text = leadingGiant + " " + giant
        let instrumentation = TextSearchInstrumentation()

        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "👩", caseSensitivity: .sensitive),
            limit: resultLimit,
            previewContextGraphemes: 40,
            instrumentation: instrumentation
        )

        let sourceLength = (text as NSString).length
        let matchLength = ("👩" as NSString).length
        let perResultBound = matchLength + 2 * TextSearchEngine.maximumPreviewContextUTF16PerSide + 2
        let composedWorkBound = sourceLength + resultLimit * 80
        XCTAssertEqual(leadingGiant.count, 1)
        XCTAssertEqual(giant.count, 1)
        XCTAssertEqual(matches.count, resultLimit)
        XCTAssertEqual(instrumentation.literalCandidatesExamined, resultLimit)
        XCTAssertLessThanOrEqual(instrumentation.uncachedComposedUTF16UnitsVisited, composedWorkBound)
        XCTAssertLessThanOrEqual(instrumentation.previewUTF16UnitsCopied, resultLimit * perResultBound)
        XCTAssertTrue(matches.allSatisfy { ($0.preview as NSString).length <= perResultBound })
        assertTextSearchMatchesAreValid(matches, in: text, expected: "👩")
    }

    func testGiantZWJGraphemeRejectedWholeWordCandidatesAreLinear() {
        let componentCount = 2000
        let giant = Array(repeating: "👩", count: componentCount).joined(separator: "\u{200D}")
        let instrumentation = TextSearchInstrumentation()
        let clock = ContinuousClock()
        let start = clock.now

        let matches = TextSearchEngine.matches(
            in: giant,
            query: TextSearchQuery(pattern: "👩", caseSensitivity: .sensitive, wholeWord: true),
            limit: componentCount,
            instrumentation: instrumentation
        )
        let elapsed = start.duration(to: .now)

        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(instrumentation.literalCandidatesExamined, 1)
        XCTAssertEqual(instrumentation.lineUTF16UnitsVisited, 0)
        XCTAssertLessThanOrEqual(
            instrumentation.uncachedComposedUTF16UnitsVisited,
            (giant as NSString).length
        )
        XCTAssertLessThanOrEqual(
            instrumentation.literalSourceUTF16UnitsVisited,
            (giant as NSString).length
        )
        XCTAssertEqual(instrumentation.previewUTF16UnitsCopied, 0)
        assertTextSearchDurationUnderLocally(elapsed, .milliseconds(250), "giant-cluster whole-word rejection")
    }

    func testLongWordCharacterLineWithRejectedWholeWordCandidatesIsLinear() {
        let length = 5 * 1024 * 1024
        let text = String(repeating: "x", count: length)
        let instrumentation = TextSearchInstrumentation()
        let clock = ContinuousClock()
        let start = clock.now
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "x", caseSensitivity: .sensitive, wholeWord: true),
            limit: 1000,
            instrumentation: instrumentation
        )
        let elapsed = start.duration(to: .now)

        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(instrumentation.literalCandidatesExamined, 0)
        XCTAssertEqual(instrumentation.lineUTF16UnitsVisited, 0)
        XCTAssertEqual(instrumentation.uncachedComposedUTF16UnitsVisited, 0)
        XCTAssertLessThanOrEqual(instrumentation.literalSourceUTF16UnitsVisited, length)
        assertTextSearchDurationUnderLocally(elapsed, .seconds(2), "5 MiB whole-word rejection")
    }

    func testLongRejectedASCIIWholeWordPatternUsesLinearLiteralCursor() {
        let sourceLength = 40000
        let patternLength = TextSearchEngine.maximumPatternUTF16Length
        let text = String(repeating: "a", count: sourceLength)
        let pattern = String(repeating: "a", count: patternLength)
        let instrumentation = TextSearchInstrumentation()
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: pattern, caseSensitivity: .sensitive, wholeWord: true),
            limit: sourceLength,
            instrumentation: instrumentation
        )

        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(instrumentation.literalCandidatesExamined, 0)
        XCTAssertLessThanOrEqual(instrumentation.literalSourceUTF16UnitsVisited, sourceLength)
    }

    func testOverlappingASCIIWholeWordCandidateRemainsDiscoverableInLinearTime() {
        let sourceRepetitions = 4000
        let patternRepetitions = 64
        let text = String(repeating: "a.", count: sourceRepetitions)
        let pattern = String(repeating: "a.", count: patternRepetitions)
        let instrumentation = TextSearchInstrumentation()
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: pattern, caseSensitivity: .sensitive, wholeWord: true),
            limit: sourceRepetitions,
            instrumentation: instrumentation
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(
            matches[0].range,
            NSRange(location: text.utf16.count - pattern.utf16.count, length: pattern.utf16.count)
        )
        XCTAssertEqual(instrumentation.literalCandidatesExamined, 1)
        XCTAssertLessThanOrEqual(instrumentation.literalSourceUTF16UnitsVisited, text.utf16.count)
    }

    func testOverlappingUnicodeWholeWordCandidatesRemainLinear() {
        let sourceRepetitions = 8000
        let patternRepetitions = 128
        let text = String(repeating: "é.", count: sourceRepetitions)
        let pattern = String(repeating: "é.", count: patternRepetitions)
        let instrumentation = TextSearchInstrumentation()
        let clock = ContinuousClock()
        let start = clock.now
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: pattern, caseSensitivity: .sensitive, wholeWord: true),
            limit: sourceRepetitions,
            instrumentation: instrumentation
        )
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(
            matches[0].range,
            NSRange(location: text.utf16.count - pattern.utf16.count, length: pattern.utf16.count)
        )
        XCTAssertEqual(
            instrumentation.literalCandidatesExamined,
            sourceRepetitions - patternRepetitions + 1
        )
        XCTAssertLessThanOrEqual(instrumentation.literalSourceUTF16UnitsVisited, text.utf16.count)
        XCTAssertLessThanOrEqual(instrumentation.literalKeyUTF16UnitsVisited, text.utf16.count * 2)
        assertTextSearchMatchesAreValid(matches, in: text, expected: pattern)
        assertTextSearchDurationUnderLocally(elapsed, .seconds(1), "Unicode periodic whole-word search")
    }
}
