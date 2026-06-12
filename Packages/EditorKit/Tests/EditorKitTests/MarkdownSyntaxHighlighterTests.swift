import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

final class MarkdownSyntaxHighlighterTests: XCTestCase {
    func testStylesHeadingsInlineMarkupLinksAndLists() throws {
        let source = """
        # Heading

        - **bold** and *italic* with `code` and [link](https://example.com)
        """

        let attributed = MarkdownSyntaxHighlighter().highlight(source, fileKind: .markdown)
        let inspected = NSAttributedString(attributed)

        let headingAttributes = try inspected.attributes(for: "Heading")
        let headingFont = try XCTUnwrap(headingAttributes[.font] as? NSFont)
        XCTAssertTrue(headingFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertGreaterThan(headingFont.pointSize, MarkdownSyntaxHighlighter.defaultFont.pointSize)

        let listMarkerAttributes = try inspected.attributes(for: "-")
        XCTAssertNotNil(listMarkerAttributes[.foregroundColor])

        let boldAttributes = try inspected.attributes(for: "bold")
        let boldFont = try XCTUnwrap(boldAttributes[.font] as? NSFont)
        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.bold))

        let italicAttributes = try inspected.attributes(for: "italic")
        let italicFont = try XCTUnwrap(italicAttributes[.font] as? NSFont)
        XCTAssertTrue(italicFont.fontDescriptor.symbolicTraits.contains(.italic))

        let codeAttributes = try inspected.attributes(for: "code")
        let codeFont = try XCTUnwrap(codeAttributes[.font] as? NSFont)
        XCTAssertTrue(codeFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertNotNil(codeAttributes[.backgroundColor])

        let linkAttributes = try inspected.attributes(for: "link")
        XCTAssertNotNil(linkAttributes[.foregroundColor])
        XCTAssertNotNil(linkAttributes[.underlineStyle])
    }

    func testStylesFrontmatterAndFencedCodeBlocks() throws {
        let source = """
        ---
        title: Test Post
        ---

        ```swift
        print("hello")
        ```
        """

        let attributed = MarkdownSyntaxHighlighter().highlight(source, fileKind: .markdown)
        let inspected = NSAttributedString(attributed)

        let frontmatterAttributes = try inspected.attributes(for: "title")
        XCTAssertNotNil(frontmatterAttributes[.foregroundColor])
        XCTAssertNotNil(frontmatterAttributes[.backgroundColor])

        let fenceLanguageAttributes = try inspected.attributes(for: "swift")
        XCTAssertNotNil(fenceLanguageAttributes[.foregroundColor])

        let fencedCodeAttributes = try inspected.attributes(for: "print")
        let fencedCodeFont = try XCTUnwrap(fencedCodeAttributes[.font] as? NSFont)
        XCTAssertTrue(fencedCodeFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertNotNil(fencedCodeAttributes[.backgroundColor])
    }

    func testStylesMDXImportsAsSourceCode() throws {
        let source = """
        import Button from "./Button"

        # Post

        <Button label="Read more" />
        """

        let attributed = MarkdownSyntaxHighlighter().highlight(source, fileKind: .mdx)
        let inspected = NSAttributedString(attributed)

        let importAttributes = try inspected.attributes(for: "import")
        let importFont = try XCTUnwrap(importAttributes[.font] as? NSFont)
        XCTAssertTrue(importFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertNotNil(importAttributes[.foregroundColor])
    }
}

private extension NSAttributedString {
    func attributes(for substring: String) throws -> [NSAttributedString.Key: Any] {
        let range = (string as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected to find substring '\(substring)'")
        return attributes(at: range.location, effectiveRange: nil)
    }
}
