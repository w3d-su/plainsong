import Foundation
@testable import MarkdownCore
import XCTest

/// A selection that covers a heading prefix shrinks with the prefix and stays inside the text.
final class HeadingToggleSelectionTests: XCTestCase {
    private func edit(
        _ command: MarkdownEditCommand,
        _ text: String,
        _ selection: NSRange
    ) throws -> (text: String, selection: NSRange) {
        let edit = try XCTUnwrap(MarkdownEditing.apply(command, to: text, selection: selection))
        let result = NSMutableString(string: text)
        result.replaceCharacters(in: edit.replacementRange, with: edit.replacementString)
        return (result as String, edit.newSelection)
    }

    func testParagraphCommandKeepsAWholeLineSelectionOnTheLine() throws {
        let result = try edit(.format(.paragraph), "### Title", NSRange(location: 0, length: 9))
        XCTAssertEqual(result.text, "Title")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 5))
    }

    func testTogglingTheSameLevelOffKeepsTheSelectionOnTheLine() throws {
        let result = try edit(.format(.heading(level: 3)), "old\n### Title\nnext", NSRange(location: 4, length: 9))
        XCTAssertEqual(result.text, "old\nTitle\nnext")
        XCTAssertEqual(result.selection, NSRange(location: 4, length: 5))
    }

    func testCaretInsideAReplacedPrefixMovesToItsEnd() throws {
        let result = try edit(.format(.heading(level: 1)), "### Title", NSRange(location: 1, length: 0))
        XCTAssertEqual(result.text, "# Title")
        XCTAssertEqual(result.selection, NSRange(location: 2, length: 0))
    }
}
