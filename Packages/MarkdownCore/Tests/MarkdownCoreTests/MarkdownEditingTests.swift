@testable import MarkdownCore
import XCTest

final class MarkdownEditingTests: XCTestCase {
    func testListContinuationBehaviors() {
        assertEdit(
            .insertNewline(fileKind: .markdown),
            from: "- 中文 item<caret>",
            to: "- 中文 item\n- <caret>"
        )

        assertEdit(
            .insertNewline(fileKind: .markdown),
            from: "1. one<caret>\n2. two\n3. three",
            to: "1. one\n2. <caret>\n3. two\n4. three"
        )

        assertEdit(
            .insertNewline(fileKind: .markdown),
            from: "1. [ ] one<caret>\n2. [x] two",
            to: "1. [ ] one\n2. [ ] <caret>\n3. [x] two"
        )

        assertEdit(
            .insertNewline(fileKind: .markdown),
            from: "- [ ] todo<caret>",
            to: "- [ ] todo\n- [ ] <caret>"
        )

        assertEdit(
            .insertNewline(fileKind: .markdown),
            from: "- done\n- <caret>",
            to: "- done\n<caret>"
        )

        assertEdit(
            .insertTab(backwards: false),
            from: "- item<caret>",
            to: "    - item<caret>"
        )

        assertEdit(
            .insertTab(backwards: true),
            from: "    - item<caret>",
            to: "- item<caret>"
        )

        assertEdit(
            .insertTab(backwards: false),
            from: "[[- one\n- two]]\nparagraph",
            to: "[[    - one\n    - two]]\nparagraph"
        )

        assertEdit(
            .insertTab(backwards: true),
            from: "[[    - one\n    - two]]\nparagraph",
            to: "[[- one\n- two]]\nparagraph"
        )
    }

    func testAutoPairingBehaviors() {
        assertEdit(
            .type("*", fileKind: .markdown),
            from: "[[中文]]",
            to: "*[[中文]]*"
        )

        XCTAssertNil(MarkdownEditing.apply(
            .type("*", fileKind: .markdown),
            to: "",
            selection: NSRange(location: 0, length: 0)
        ))

        assertEdit(
            .type("(", fileKind: .markdown),
            from: "hello <caret>",
            to: "hello (<caret>)"
        )

        assertEdit(
            .type(")", fileKind: .markdown),
            from: "(<caret>)",
            to: "()<caret>"
        )

        assertEdit(
            .type("`", fileKind: .markdown),
            from: "[[code]]",
            to: "`[[code]]`"
        )

        assertEdit(
            .type("<", fileKind: .mdx),
            from: "<caret>",
            to: "<<caret>>"
        )

        XCTAssertNil(MarkdownEditing.apply(
            .type("<", fileKind: .markdown),
            to: "",
            selection: NSRange(location: 0, length: 0)
        ))
    }

    func testCodeFenceHelperInsertsClosingFence() {
        assertEdit(
            .insertNewline(fileKind: .markdown),
            from: "```<caret>",
            to: "```\n<caret>\n```"
        )
    }

    func testCodeFenceHelperDoesNotInsertFenceFromClosingFence() {
        let input = MarkedText("```swift\nprint(\"hi\")\n```<caret>")

        XCTAssertNil(MarkdownEditing.apply(
            .insertNewline(fileKind: .markdown),
            to: input.text,
            selection: input.selection
        ))
    }

    func testCheckboxToggleBehaviors() {
        assertEdit(
            .toggleCheckbox,
            from: "- [ ] one<caret>",
            to: "- [x] one<caret>"
        )

        assertEdit(
            .toggleCheckbox,
            from: "- [ ] one\n[[- [x] two\n- [ ] 三]]",
            to: "- [ ] one\n[[- [ ] two\n- [x] 三]]"
        )

        assertEdit(
            .toggleCheckbox,
            from: "<caret>- item",
            to: "<caret>- [ ] item"
        )
    }

    func testCheckboxTogglePreservesCRLFLineEndings() {
        assertEdit(
            .toggleCheckbox,
            from: "[[  \r\nplain]]",
            to: "[[- [ ] \r\n- [ ] plain]]"
        )
    }

    func testLineSelectionsIncludeLastLineWhenSelectionEndsAtLineStart() {
        struct TestCase {
            let name: String
            let command: MarkdownEditCommand
            let input: String
            let expected: String
        }

        let testCases: [TestCase] = [
            .init(
                name: "checkbox",
                command: .toggleCheckbox,
                input: "[[a\nb]]",
                expected: "[[- [ ] a\n- [ ] b]]"
            ),
            .init(
                name: "quote",
                command: .format(.quote),
                input: "[[a\nb]]",
                expected: "[[> a\n> b]]"
            ),
        ]

        for testCase in testCases {
            XCTContext.runActivity(named: testCase.name) { _ in
                assertEdit(testCase.command, from: testCase.input, to: testCase.expected)
            }
        }
    }

    func testBlockListTabPreservesCRLFLineEndings() {
        assertEdit(
            .insertTab(backwards: false),
            from: "[[- one\r\n- two]]\r\nparagraph",
            to: "[[    - one\r\n    - two]]\r\nparagraph"
        )
    }

    func testTableBehaviors() {
        assertEdit(
            .formatTable,
            from: "|Name|Qty|\n|---|---:|\n|茶|2|\n|Longer|10|",
            to: "| Name   | Qty |\n| ------ | --: |\n| 茶     | 2   |\n| Longer | 10  |"
        )

        assertEdit(
            .insertTab(backwards: false),
            from: "| A | B |\n| --- | --- |\n| one<caret>| two |\n      ",
            to: "| A | B |\n| --- | --- |\n| one| [[two]] |\n      "
        )

        assertEdit(
            .insertTab(backwards: true),
            from: "| A | B |\n| --- | --- |\n| one | [[two]] |\n       ",
            to: "| A | B |\n| --- | --- |\n| [[one]] | two |\n       "
        )

        assertEdit(
            .insertNewline(fileKind: .markdown),
            from: "| A | B |\n| --- | --- |\n| one | two |<caret>",
            to: "| A | B |\n| --- | --- |\n| one | two |\n| [[ ]]|  |"
        )
    }

    func testFormattingCommands() {
        assertEdit(
            .format(.bold),
            from: "[[中文]]",
            to: "**[[中文]]**"
        )

        assertEdit(
            .format(.bold),
            from: "**[[中文]]**",
            to: "[[中文]]"
        )

        assertEdit(
            .format(.italic),
            from: "<caret>",
            to: "*<caret>*"
        )

        assertEdit(
            .format(.link),
            from: "[[Plainsong]]",
            to: "[Plainsong](<caret>)"
        )

        assertEdit(
            .format(.heading(level: 2)),
            from: "old\nTitle<caret>",
            to: "old\n## Title<caret>"
        )

        assertEdit(
            .format(.heading(level: 2)),
            from: "## Title<caret>",
            to: "Title<caret>"
        )

        assertEdit(
            .format(.paragraph),
            from: "### Title<caret>",
            to: "Title<caret>"
        )

        assertEdit(
            .format(.quote),
            from: "Quote me<caret>",
            to: "> Quote me<caret>"
        )

        assertEdit(
            .format(.quote),
            from: "> Quote me<caret>",
            to: "Quote me<caret>"
        )
    }

    func testQuoteTogglePreservesCRLFLineEndings() {
        assertEdit(
            .format(.quote),
            from: "[[one\r\ntwo]]",
            to: "[[> one\r\n> two]]"
        )
    }

    func testCodeFenceFormattingCommand() {
        assertEdit(
            .format(.codeFence),
            from: "[[print(\"hi\")]]",
            to: "```\n[[print(\"hi\")]]\n```"
        )

        assertEdit(
            .format(.codeFence),
            from: "[[```\n```]]",
            to: "```\n[[```\n```]]\n```"
        )
    }

    func testIMEGuardDecision() {
        XCTAssertFalse(MarkdownEditing.shouldHandleBehavior(hasMarkedText: true))
        XCTAssertTrue(MarkdownEditing.shouldHandleBehavior(hasMarkedText: false))
    }

    private func assertEdit(
        _ command: MarkdownEditCommand,
        from rawInput: String,
        to rawExpected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let input = MarkedText(rawInput)
        let expected = MarkedText(rawExpected)
        guard let edit = MarkdownEditing.apply(command, to: input.text, selection: input.selection) else {
            XCTFail("Expected edit", file: file, line: line)
            return
        }

        let actualText = apply(edit, to: input.text)
        XCTAssertEqual(actualText, expected.text, file: file, line: line)
        XCTAssertEqual(edit.newSelection, expected.selection, file: file, line: line)
    }

    private func apply(_ edit: MarkdownEditResult, to text: String) -> String {
        let mutableText = NSMutableString(string: text)
        mutableText.replaceCharacters(in: edit.replacementRange, with: edit.replacementString)
        return mutableText as String
    }
}

private struct MarkedText {
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
