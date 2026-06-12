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

    func testStatisticsAreEquatableAndSendable() {
        let statistics = TextStatistics(text: "same text")

        XCTAssertEqual(statistics, TextStatistics(text: "same text"))
        assertSendable(statistics)
    }
}

private func assertSendable(_ value: some Sendable) {
    _ = value
}
