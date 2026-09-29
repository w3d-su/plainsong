import Foundation
@testable import MarkdownCore
import XCTest

/// Parses `<caret>` (collapsed) or `[[selection]]` markers out of a fixture string
/// and reports the selection in UTF-16 units.
struct MathMarkedText {
    let text: String
    let selection: NSRange

    init(_ raw: String) {
        if let start = raw.range(of: "[["), let end = raw.range(of: "]]") {
            var text = raw
            text.removeSubrange(end)
            text.removeSubrange(start)

            let location = raw[..<start.lowerBound].utf16.count
            let length = raw[start.upperBound ..< end.lowerBound].utf16.count
            self.text = text
            selection = NSRange(location: location, length: length)
            return
        }

        guard let cursorRange = raw.range(of: "<caret>") else {
            self.text = raw
            selection = NSRange(location: 0, length: 0)
            return
        }

        var text = raw
        text.removeSubrange(cursorRange)
        self.text = text
        selection = NSRange(location: raw[..<cursorRange.lowerBound].utf16.count, length: 0)
    }
}

extension XCTestCase {
    func assertMathEdit(
        _ command: MarkdownFormattingCommand,
        from rawInput: String,
        to rawExpected: String,
        fileKind: FileKind = .markdown,
        expectSelectionOnly: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let input = MathMarkedText(rawInput)
        let expected = MathMarkedText(rawExpected)
        guard let edit = MarkdownEditing.apply(
            .format(command),
            to: input.text,
            selection: input.selection,
            fileKind: fileKind
        ) else {
            XCTFail("Expected edit", file: file, line: line)
            return
        }

        if expectSelectionOnly {
            XCTAssertEqual(edit.replacementString, "", file: file, line: line)
            XCTAssertEqual(edit.replacementRange.length, 0, file: file, line: line)
        }

        let mutableText = NSMutableString(string: input.text)
        mutableText.replaceCharacters(in: edit.replacementRange, with: edit.replacementString)
        XCTAssertEqual(mutableText as String, expected.text, file: file, line: line)
        XCTAssertEqual(edit.newSelection, expected.selection, file: file, line: line)
    }

    func assertNoMathEdit(
        _ command: MarkdownFormattingCommand,
        from rawInput: String,
        fileKind: FileKind = .markdown,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let input = MathMarkedText(rawInput)
        let edit = MarkdownEditing.apply(
            .format(command),
            to: input.text,
            selection: input.selection,
            fileKind: fileKind
        )
        XCTAssertNil(edit, "Expected no-op", file: file, line: line)
    }

    func assertNoMathEditBoth(
        from rawInput: String,
        fileKind: FileKind = .markdown,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertNoMathEdit(.insertInlineMath, from: rawInput, fileKind: fileKind, file: file, line: line)
        assertNoMathEdit(.insertDisplayMath, from: rawInput, fileKind: fileKind, file: file, line: line)
    }
}
