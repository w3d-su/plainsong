@testable import MarkdownCore
import XCTest

final class TextStatisticsTests: XCTestCase {
    func testEmptyTextHasNoCharactersNoWordsAndOneLine() {
        let statistics = TextStatistics(text: "")

        XCTAssertEqual(statistics.characterCount, 0)
        XCTAssertEqual(statistics.wordCount, 0)
        XCTAssertEqual(statistics.lineCount, 1)
    }

    func testCountsCharactersWordsAndLines() {
        let text = "Hello, world!\n\nThis is Markdown."
        let statistics = TextStatistics(text: text)

        XCTAssertEqual(statistics.characterCount, text.count)
        XCTAssertEqual(statistics.wordCount, 5)
        XCTAssertEqual(statistics.lineCount, 3)
    }

    func testTrailingNewlineCreatesAnotherLine() {
        let statistics = TextStatistics(text: "one\n")

        XCTAssertEqual(statistics.wordCount, 1)
        XCTAssertEqual(statistics.lineCount, 2)
    }

    func testCountsCJKWordsUsingWordBoundaries() {
        let statistics = TextStatistics(text: "我正在寫中文部落格")

        XCTAssertEqual(statistics.wordCount, 6)
    }

    func testCountingWithoutMaterializingWordsKeepsFoundationBoundaries() {
        let samples = ["", "中文 English 123_456—café", "e\u{301} 👩🏽‍💻\r\n\n台北", "  'shell'  3.14?!  "]
        for text in samples {
            var words: [String] = []
            text.enumerateSubstrings(in: text.startIndex ..< text.endIndex, options: .byWords) { word, _, _, _ in
                if let word { words.append(word) }
            }
            let counts = TextStatistics(text: text)
            XCTAssertEqual(counts.wordCount, words.count, text)
            XCTAssertEqual(counts.characterCount, text.count, text)
            XCTAssertEqual(counts.lineCount, 1 + text.filter(\.isNewline).count, text)
        }
    }

    func testStatisticsAreEquatableAndSendable() {
        let statistics = TextStatistics(text: "same text")

        XCTAssertEqual(statistics, TextStatistics(text: "same text"))
        assertSendable(statistics)
    }
}

private func assertSendable(_ value: some Sendable) {
    _ = value
}
