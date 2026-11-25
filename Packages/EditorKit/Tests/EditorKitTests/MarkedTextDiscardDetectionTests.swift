@testable import EditorKit
import XCTest

@MainActor
final class MarkedTextDiscardDetectionTests: XCTestCase {
    private let fullText = "前文ㄓㄨ後文"
    private let markedRange = NSRange(location: 2, length: 2)

    private func length(_ currentText: String, stray: [String] = ["\n", "\r"]) -> Int? {
        MarkdownSTTextView.discardedReplacementLength(
            currentText: currentText,
            fullText: fullText,
            markedRange: markedRange,
            strayReplacements: stray
        )
    }

    func testDiscardedMarkedTextIsDetected() {
        XCTAssertEqual(length("前文後文"), 0)
        XCTAssertEqual(length("前文\n後文"), 1)
        XCTAssertEqual(length("前文 後文", stray: [" "]), 1)
    }

    func testCommittedOrEditedTextIsNotADiscard() {
        XCTAssertNil(length("前文注後文"))
        XCTAssertNil(length("前文ㄓㄨ後文"))
        XCTAssertNil(length("前文後字"))
        XCTAssertNil(length("前文x後文"))
    }
}
