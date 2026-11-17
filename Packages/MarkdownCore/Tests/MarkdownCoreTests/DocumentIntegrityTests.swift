@testable import MarkdownCore
import XCTest

final class DocumentIntegrityTests: XCTestCase {
    func testLinkPreservesSelectionThatSpansMultipleLinks() throws {
        for selection in [
            "[第一份](a.md)\n\n尚未發表的內文\n\n[第二份](b.md)",
            "[one](a) and [two](b)",
            "[one](a) and (a trailing remark)",
            "[one](not a link destination)",
            "[one](<a<b> c>)",
        ] {
            let edit = try linkEdit(selection)
            XCTAssertEqual(edit.replacementString, "[\(selection)]()")
            XCTAssertEqual(edit.newSelection.length, 0)
        }
    }

    func testLinkUnwrapsOneCompleteLinkWithEscapesOrTitle() throws {
        for (selection, label) in [
            ("[文件](a.md)", "文件"),
            (#"[part \] one](docs/a(b).md "title")"#, #"part \] one"#),
            ("[a [b]](<file name.md> 'some title')", "a [b]"),
            ("[empty]()", "empty"),
        ] {
            let edit = try linkEdit(selection)
            XCTAssertEqual(edit.replacementString, label)
            XCTAssertEqual(edit.newSelection, NSRange(location: 0, length: label.utf16.count))
        }
    }

    func testDefaultFrontmatterParsesWithEmptyTitleAndPreservesBody() throws {
        for ending in ["\n", "\r\n", "\r"] {
            let body = "正文" + ending
            let added = Frontmatter.insertingDefaultBlock(into: body, date: "2026-11-18")
            let parsed = Frontmatter.parse(added)
            XCTAssertNil(parsed.error)
            let fields = try XCTUnwrap(parsed.block).fieldValues
            XCTAssertEqual(fields["title"], .string(""))
            XCTAssertEqual(fields["draft"], .bool(false))
            XCTAssertTrue(added.hasSuffix("---" + ending + body))
        }
    }

    func testEditPreservesInlineAndIndentedCommentsVerbatim() {
        let source = "---\r\ntitle: \"繁體 # 字串\"  # 出版備註\r\n  # 第二則\r\ndraft: true\r\n---\r\n"
        let expected = source.replacingOccurrences(of: "\"繁體 # 字串\"", with: "\"New\"")
        XCTAssertEqual(Frontmatter.updating(source, key: "title", value: .string("New")), expected)
    }

    func testEditDistinguishesBlockScalarContentFromHeaderComment() {
        let source = "---\ntitle: | # note\n  # part of the title\nslug: post\n---\n"
        let expected = "---\ntitle: \"New\" # note\nslug: post\n---\n"
        XCTAssertEqual(Frontmatter.updating(source, key: "title", value: .string("New")), expected)
    }

    func testReplacingListPreservesCommentsFromRemovedElements() {
        let source = "---\ntags: # topics\n  - one # keep\n  # review\n  - 'two # literal'\n---\n"
        let expected = "---\ntags: [] # topics\n  # keep\n  # review\n---\n"
        XCTAssertEqual(Frontmatter.updating(source, key: "tags", value: .stringList([])), expected)
    }

    private func linkEdit(_ source: String) throws -> MarkdownEditResult {
        try XCTUnwrap(MarkdownEditing.apply(
            .format(.link), to: source, selection: NSRange(location: 0, length: source.utf16.count)
        ))
    }
}
