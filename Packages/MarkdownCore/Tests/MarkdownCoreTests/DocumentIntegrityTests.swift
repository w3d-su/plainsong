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
            ("[`a]`](x.md)", "`a]`"),
            ("[``a ` [ ] ]``](x.md)", "``a ` [ ] ]``"),
            ("[unmatched `tick](x.md)", "unmatched `tick"),
            ("[q](https://e.com/?a<b>c)", "q"),
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

    func testEditedDateAndTagsKeepCommentsOutsideTheirValues() throws {
        let source = "---\ndate: 2026-01-01 # updated\ntags: a, b # c\n---\n正文"
        let fields = try XCTUnwrap(Frontmatter.parse(source).block).fieldValues
        XCTAssertEqual(fields["date"], .date("2026-01-01"))
        XCTAssertEqual(fields["tags"], .stringList(["a", "b"]))
        let changed = try XCTUnwrap(Frontmatter.updating(source, key: "date", value: .date("2026-01-02")))
        XCTAssertEqual(changed, source.replacingOccurrences(of: "2026-01-01", with: "2026-01-02"))
        guard case var .stringList(tags) = fields["tags"] else { return XCTFail("missing tags") }
        tags.append("d")
        let updated = try XCTUnwrap(Frontmatter.updating(changed, key: "tags", value: .stringList(tags)))
        XCTAssertEqual(updated, changed.replacingOccurrences(
            of: "tags: a, b # c", with: "tags: # c\n  - \"a\"\n  - \"b\"\n  - \"d\""
        ))
        XCTAssertEqual(Frontmatter.parse(updated).block?.fieldValues["tags"], .stringList(["a", "b", "d"]))
        let literal = "---\ndate: 'day # 1' # note\ntags: 'c#, f#' # note\n---\n"
        let quoted = try XCTUnwrap(Frontmatter.parse(literal).block).fieldValues
        XCTAssertEqual(quoted["date"], .date("day # 1"))
        XCTAssertEqual(quoted["tags"], .stringList(["c#", "f#"]))
    }

    func testUnicodeLineBreaksLeaveLiteralHashesAndOriginalSeparatorsIntact() {
        for separator in ["\u{85}", "\u{2028}", "\u{2029}"] {
            let prefix = "---\r\nsummary: \"中\(separator)title: 文字\"\r\n"
            let source = prefix + "title: \"C# tips\"  # keep\r\n---\r\n"
            XCTAssertEqual(Frontmatter.updating(source, key: "title", value: .string("New")),
                           prefix + "title: \"New\"  # keep\r\n---\r\n")
        }
    }

    private func linkEdit(_ source: String) throws -> MarkdownEditResult {
        try XCTUnwrap(MarkdownEditing.apply(
            .format(.link), to: source, selection: NSRange(location: 0, length: source.utf16.count)
        ))
    }
}
