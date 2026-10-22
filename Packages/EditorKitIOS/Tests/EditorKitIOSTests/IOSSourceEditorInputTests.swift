@testable import EditorKitIOS
import MarkdownCore
import UIKit
import XCTest

final class IOSSourceEditorInputTests: XCTestCase {
    @MainActor
    func testTextKit2SurfaceAcceptsTraditionalChineseEmojiAndPasteOnceEach() {
        let harness = IOSEditorHarness(text: "")
        XCTAssertTrue(harness.controller.isTextKit2)
        XCTAssertNotNil(harness.textView.textLayoutManager)
        XCTAssertNil(harness.textView.viewportOverride)

        let version = harness.session.version
        harness.textView.insertText("繁體輸入")
        XCTAssertEqual(harness.textView.textStorage.string, "繁體輸入")
        XCTAssertEqual(harness.session.text, "繁體輸入")
        XCTAssertEqual(harness.session.version, version + 1)

        harness.textView.insertText("😀")
        XCTAssertEqual(harness.session.version, version + 2)
        let emojiLocation = iosUTF16("繁體輸入")
        XCTAssertEqual(iosUTF16("😀"), 2)
        harness.textView.selectedRange = NSRange(location: emojiLocation, length: 2)
        XCTAssertEqual(harness.textView.selectedRange.length, 2)

        let beforePaste = harness.session.version
        harness.placeCaret(at: iosUTF16(harness.textView.textStorage.string))
        harness.textView.insertText("貼上\n第二行")
        XCTAssertEqual(harness.session.version, beforePaste + 1)
        XCTAssertTrue(harness.textView.textStorage.string.hasSuffix("貼上\n第二行"))
        XCTAssertEqual(harness.session.text, harness.textView.textStorage.string)
    }

    @MainActor
    func testEnterTabPairFenceAndTableUseMarkdownEditingOnce() throws {
        let list = IOSEditorHarness(text: "- 中文 item")
        list.placeCaret(at: iosUTF16("- 中文 item"))
        let listVersion = list.session.version
        list.textView.insertText("\n")
        XCTAssertEqual(list.textView.textStorage.string, "- 中文 item\n- ")
        XCTAssertEqual(list.session.version, listVersion + 1)

        let indent = IOSEditorHarness(text: "- one\n- two\nparagraph")
        indent.textView.selectedRange = NSRange(location: 0, length: iosUTF16("- one\n- two"))
        indent.textView.insertText("\t")
        XCTAssertEqual(indent.textView.textStorage.string, "    - one\n    - two\nparagraph")

        let outdent = IOSEditorHarness(text: "    - item")
        outdent.placeCaret(at: iosUTF16("    - item"))
        let command = try XCTUnwrap(
            outdent.textView.keyCommands?.first { $0.input == "\t" && $0.modifierFlags.contains(.shift) }
        )
        outdent.textView.perform(command.action, with: nil)
        XCTAssertEqual(outdent.textView.textStorage.string, "- item")

        let pair = IOSEditorHarness(text: "中文")
        pair.textView.selectedRange = NSRange(location: 0, length: iosUTF16("中文"))
        pair.textView.insertText("*")
        XCTAssertEqual(pair.textView.textStorage.string, "*中文*")

        let fence = IOSEditorHarness(text: "```")
        fence.placeCaret(at: 3)
        fence.textView.insertText("\n")
        XCTAssertEqual(fence.textView.textStorage.string, "```\n\n```")

        let tableSource = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        let table = IOSEditorHarness(text: tableSource)
        let caret = iosUTF16(tableSource)
        table.placeCaret(at: caret)
        let expected = try XCTUnwrap(MarkdownEditing.apply(
            .insertNewline(fileKind: .markdown),
            to: tableSource,
            selection: NSRange(location: caret, length: 0)
        ))
        let raw = (tableSource as NSString).replacingCharacters(
            in: NSRange(location: caret, length: 0),
            with: "\n"
        )
        XCTAssertNotEqual(expected.replacementString, "\n")
        table.textView.insertText("\n")
        let applied = (tableSource as NSString).replacingCharacters(
            in: expected.replacementRange,
            with: expected.replacementString
        )
        XCTAssertEqual(table.textView.textStorage.string, applied)
        XCTAssertNotEqual(table.textView.textStorage.string, raw)
    }
}
