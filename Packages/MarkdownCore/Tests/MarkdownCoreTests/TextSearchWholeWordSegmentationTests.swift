@testable import MarkdownCore
import XCTest

/// Whole Word next to scripts written without spaces. Every Han, kana or Thai letter is a
/// word character, so the scalar rule alone found nothing inside running text; at those
/// edges ICU word segmentation (root locale) decides instead.
final class TextSearchWholeWordSegmentationTests: XCTestCase {
    func testFindsAHanWordInsideRunningText() {
        XCTAssertEqual(wholeWordMatches("中文", in: "我喜歡中文。"), [NSRange(location: 3, length: 2)])
        XCTAssertEqual(
            wholeWordMatches("中文", in: "這是中文，那是英文。我喜歡中文"),
            [NSRange(location: 2, length: 2), NSRange(location: 13, length: 2)]
        )
    }

    func testFindsALatinWordBetweenHanCharacters() {
        let text = "使用Swift開發"
        XCTAssertEqual(wholeWordMatches("Swift", in: text), [NSRange(location: 2, length: 5)])
        XCTAssertEqual(
            wholeWordMatches("swift", in: text, caseSensitivity: .insensitive),
            [NSRange(location: 2, length: 5)]
        )
        XCTAssertEqual(
            wholeWordMatches("Markdown", in: "我們使用Markdown寫作"),
            [NSRange(location: 4, length: 8)]
        )
    }

    func testRejectsPartOfASegmentedWord() {
        XCTAssertEqual(wholeWordMatches("喜", in: "我喜歡中文。"), [])
        XCTAssertEqual(wholeWordMatches("歡中", in: "我喜歡中文。"), [])
        XCTAssertEqual(wholeWordMatches("wif", in: "使用Swift開發"), [])
    }

    func testRejectedCandidateDoesNotSkipALaterWordInTheSameRun() {
        // 文章|與|文: the first 文 is inside 文章, the second is a word of its own.
        XCTAssertEqual(wholeWordMatches("文", in: "文章與文"), [NSRange(location: 3, length: 1)])
    }

    func testSegmentsKanaKatakanaAndThai() {
        XCTAssertEqual(
            wholeWordMatches("テキスト", in: "日本語のテキストです"),
            [NSRange(location: 4, length: 4)]
        )
        XCTAssertEqual(wholeWordMatches("タワー", in: "東京タワー"), [NSRange(location: 2, length: 3)])
        let thai = "ภาษาไทยง่ายนิดเดียว"
        XCTAssertEqual(wholeWordMatches("ง่าย", in: thai), [(thai as NSString).range(of: "ง่าย")])
    }

    func testHangulAndLatinWordsKeepTheScalarRule() {
        XCTAssertEqual(wholeWordMatches("한국", in: "한국어를 공부해요"), [])
        XCTAssertEqual(wholeWordMatches("cat", in: "catalog 中cat"), [NSRange(location: 9, length: 3)])
        XCTAssertEqual(wholeWordMatches("cat", in: "concat"), [])
    }

    func testUnbrokenHanRunTokenizesLinearly() {
        let text = String(repeating: "我喜歡中文", count: 100_000)
        let length = (text as NSString).length
        let instrumentation = TextSearchInstrumentation()
        let clock = ContinuousClock()
        let start = clock.now
        let matches = TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: "喜", caseSensitivity: .sensitive, wholeWord: true),
            limit: 10,
            instrumentation: instrumentation
        )
        let elapsed = start.duration(to: .now)

        XCTAssertTrue(matches.isEmpty)
        XCTAssertEqual(instrumentation.literalCandidatesExamined, 100_000)
        // Each window is tokenized once and covers about `windowSpan` new units.
        XCTAssertLessThanOrEqual(
            instrumentation.wordSegmentationUTF16UnitsVisited,
            length + length / 4 + TextSearchWordSegmentation.windowSpan
        )
        assertTextSearchDurationUnderLocally(elapsed, .seconds(3), "500k-unit unbroken Han run")
    }

    func testSearchesThatNeverTouchSegmentedScriptsNeverTokenize() {
        let instrumentation = TextSearchInstrumentation()
        _ = TextSearchEngine.matches(
            in: "catalog cat concat 한국어 cat",
            query: TextSearchQuery(pattern: "cat", caseSensitivity: .sensitive, wholeWord: true),
            limit: 10,
            instrumentation: instrumentation
        )
        XCTAssertEqual(instrumentation.wordSegmentationWindows, 0)
    }

    func testUsesWordSegmentationScalarClassification() throws {
        for scalar in ["中", "々", "〇", "あ", "ア", "ー", "ｱ", "ก", "ລ", "က", "ក", "𠀀"] {
            XCTAssertTrue(
                try TextSearchWordBoundary.usesWordSegmentation(XCTUnwrap(Unicode.Scalar(scalar))),
                "\(scalar) is segmented"
            )
        }
        for scalar in ["a", "é", "Ж", "한", "ㄅ", "1", "_", "。", "、", "😀"] {
            XCTAssertFalse(
                try TextSearchWordBoundary.usesWordSegmentation(XCTUnwrap(Unicode.Scalar(scalar))),
                "\(scalar) keeps the scalar rule"
            )
        }
    }

    private func wholeWordMatches(
        _ pattern: String,
        in text: String,
        caseSensitivity: TextSearchCaseSensitivity = .sensitive
    ) -> [NSRange] {
        TextSearchEngine.matches(
            in: text,
            query: TextSearchQuery(pattern: pattern, caseSensitivity: caseSensitivity, wholeWord: true),
            limit: 20
        ).map(\.range)
    }
}
