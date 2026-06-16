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

    func testStylesMDXImportsAndJSXWithTSXTokens() throws {
        let source = """
        import Button from "./Button"
        export const label = "Read more"

        # Post

        <Button label="Read more" />
        """

        let tokens = try MarkdownSyntaxParser().tokens(in: source, fileKind: .mdx)
        XCTAssertFalse(tokens.contains(kind: .mdxSource))
        XCTAssertTrue(tokens.kinds(in: source, for: "import").contains(.tsxKeyword))
        XCTAssertTrue(tokens.kinds(in: source, for: "\"./Button\"").contains(.tsxString))
        XCTAssertTrue(tokens.kinds(in: source, for: "Button label").contains(.tsxTag))
        XCTAssertTrue(tokens.kinds(in: source, for: "label=").contains(.tsxAttribute))

        let attributed = MarkdownSyntaxHighlighter().highlight(source, fileKind: .mdx)
        let inspected = NSAttributedString(attributed)

        let importAttributes = try inspected.attributes(for: "import")
        let importFont = try XCTUnwrap(importAttributes[.font] as? NSFont)
        XCTAssertTrue(importFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertEqual(importAttributes[.foregroundColor] as? NSColor, MarkdownSyntaxTheme.standard.tsxKeywordColor)

        let stringAttributes = try inspected.attributes(for: "\"./Button\"")
        XCTAssertEqual(stringAttributes[.foregroundColor] as? NSColor, MarkdownSyntaxTheme.standard.tsxStringColor)

        let attributeAttributes = try inspected.attributes(for: "label=\"Read more\"")
        XCTAssertEqual(
            attributeAttributes[.foregroundColor] as? NSColor,
            MarkdownSyntaxTheme.standard.tsxAttributeColor
        )
    }

    func testMDXFixturesProduceTSXTokensInsteadOfCoarseSource() throws {
        for fixtureName in ["kitchen-sink.mdx", "product-page.mdx"] {
            let source = try String(contentsOf: Self.repoRoot.appending(path: "Fixtures/\(fixtureName)"))
            let tokens = try MarkdownSyntaxParser().tokens(in: source, fileKind: .mdx)

            XCTAssertFalse(tokens.contains(kind: .mdxSource), fixtureName)
            XCTAssertTrue(tokens.contains(kind: .tsxKeyword), fixtureName)
            XCTAssertTrue(tokens.contains(kind: .tsxString), fixtureName)
            XCTAssertTrue(tokens.contains(kind: .tsxTag), fixtureName)
            XCTAssertTrue(tokens.contains(kind: .tsxAttribute), fixtureName)
        }
    }

    func testMarkdownFilesDoNotReceiveMDXTSXTokens() throws {
        let source = """
        import Button from "./Button"

        # Post

        <Button label="Read more" />

        Text with <Em>x</Em> inline.
        """

        let tokens = try MarkdownSyntaxParser().tokens(in: source, fileKind: .markdown)

        XCTAssertFalse(tokens.contains(kind: .mdxSource))
        XCTAssertFalse(tokens.containsTSXToken)
    }

    func testStylesMidParagraphInlineJSXWithTSXTokens() throws {
        let source = "Text with <Em>x</Em> inline.\nA <Tag/> mid line."

        let tokens = try MarkdownSyntaxParser().tokens(in: source, fileKind: .mdx)

        XCTAssertFalse(tokens.contains(kind: .mdxSource))
        XCTAssertEqual(tokens.ranges(kind: .tsxTag), source.ranges(of: "Em") + source.ranges(of: "Tag"))

        let nsSource = source as NSString
        let openingRange = nsSource.range(of: "<Em>")
        let closingRange = nsSource.range(of: "</Em>")
        let selfClosingRange = nsSource.range(of: "<Tag/>")
        XCTAssertEqual(tokens.ranges(kind: .tsxPunctuation), [
            NSRange(location: openingRange.location, length: 1),
            NSRange(location: NSMaxRange(openingRange) - 1, length: 1),
            NSRange(location: closingRange.location, length: 1),
            NSRange(location: NSMaxRange(closingRange) - 1, length: 1),
            NSRange(location: selfClosingRange.location, length: 1),
            NSRange(location: NSMaxRange(selfClosingRange) - 2, length: 2),
        ])

        assertNoOverlappingTSXTokens(tokens)
    }

    func testLineStartJSXDoesNotEmitDuplicateOverlappingTSXTokens() throws {
        let source = "<Button>top level</Button>"

        let tokens = try MarkdownSyntaxParser().tokens(in: source, fileKind: .mdx)

        XCTAssertEqual(tokens.ranges(kind: .tsxTag), source.ranges(of: "Button"))
        assertNoOverlappingTSXTokens(tokens)
    }

    func testFencedTSXCodeKeepsCodeFenceHighlightingInMDX() throws {
        let source = """
        # Example

        ```tsx
        export function Badge({ label }: { label: string }) {
          return <span className="badge">{label}</span>
        }
        ```

        <Button label="Read more" />
        """

        let tokens = try MarkdownSyntaxParser().tokens(in: source, fileKind: .mdx)
        let fencedExportKinds = tokens.kinds(in: source, for: "export function")

        XCTAssertTrue(fencedExportKinds.contains(.codeBlock))
        XCTAssertFalse(fencedExportKinds.contains(.tsxKeyword))
        XCTAssertTrue(tokens.kinds(in: source, for: "Button label").contains(.tsxTag))
    }

    func testLargeMDXFallsBackToCoarseSourceAboveInlineLimit() throws {
        let filler = String(repeating: "Plain paragraph without inline markup.\n", count: 8000)
        let source = """
        import Hero from "./Hero"

        \(filler)

        <Hero title="Large document" />
        """

        XCTAssertGreaterThan(source.utf8.count, MarkdownSyntaxParser.inlineParsingLimit)

        let tokens = try MarkdownSyntaxParser().tokens(in: source, fileKind: .mdx)

        XCTAssertTrue(tokens.contains(kind: .mdxSource))
        XCTAssertFalse(tokens.containsTSXToken)
    }

    func testEscapedEmphasisDelimitersStayPlainText() throws {
        let source = #"Escaped \*not italic\* text"#

        let attributed = MarkdownSyntaxHighlighter().highlight(source, fileKind: .markdown)
        let inspected = NSAttributedString(attributed)

        let escapedAttributes = try inspected.attributes(for: "not italic")
        let escapedFont = try XCTUnwrap(escapedAttributes[.font] as? NSFont)
        XCTAssertFalse(escapedFont.fontDescriptor.symbolicTraits.contains(.italic))
    }

    func testCJKStrongEmphasisIsBold() throws {
        let source = "段落**中文粗體**結尾"

        let attributed = MarkdownSyntaxHighlighter().highlight(source, fileKind: .markdown)
        let inspected = NSAttributedString(attributed)

        let boldAttributes = try inspected.attributes(for: "中文粗體")
        let boldFont = try XCTUnwrap(boldAttributes[.font] as? NSFont)
        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testCJKBoldDoesNotLeakIntoNeighboringText() throws {
        let source = "段落**中文粗體**結尾"

        let attributed = MarkdownSyntaxHighlighter().highlight(source, fileKind: .markdown)
        let inspected = NSAttributedString(attributed)

        let leadingFont = try XCTUnwrap(inspected.attributes(for: "段落")[.font] as? NSFont)
        XCTAssertFalse(leadingFont.fontDescriptor.symbolicTraits.contains(.bold))

        let trailingFont = try XCTUnwrap(inspected.attributes(for: "結尾")[.font] as? NSFont)
        XCTAssertFalse(trailingFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testCJKBoldSurroundedByFullwidthPunctuation() throws {
        let source = "# 中文標題\n\n前面有中文，**粗體文字**，後面也有。\n"

        let attributed = MarkdownSyntaxHighlighter().highlight(source, fileKind: .markdown)
        let inspected = NSAttributedString(attributed)

        let headingFont = try XCTUnwrap(inspected.attributes(for: "中文標題")[.font] as? NSFont)
        XCTAssertTrue(headingFont.fontDescriptor.symbolicTraits.contains(.bold))

        let boldFont = try XCTUnwrap(inspected.attributes(for: "粗體文字")[.font] as? NSFont)
        XCTAssertTrue(
            boldFont.fontDescriptor.symbolicTraits.contains(.bold),
            "CJK strong emphasis surrounded by fullwidth punctuation must stay bold"
        )
    }

    func testPipeTableHeaderAndDelimitersAreStyled() throws {
        let source = """
        | Name | Value |
        | ---- | ----- |
        | One  | 1     |
        """

        let attributed = MarkdownSyntaxHighlighter().highlight(source, fileKind: .markdown)
        let inspected = NSAttributedString(attributed)

        let headerFont = try XCTUnwrap(inspected.attributes(for: "Name")[.font] as? NSFont)
        XCTAssertTrue(headerFont.fontDescriptor.symbolicTraits.contains(.bold))

        let delimiterColor = try inspected.attributes(for: "----")[.foregroundColor] as? NSColor
        XCTAssertEqual(delimiterColor, MarkdownSyntaxTheme.standard.mutedColor)

        let bodyFont = try XCTUnwrap(inspected.attributes(for: "One")[.font] as? NSFont)
        XCTAssertFalse(bodyFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testLargeDocumentsStillReceiveBlockParserHighlighting() throws {
        let filler = String(repeating: "Plain paragraph without inline markup.\n", count: 8000)
        let source = filler + "\n## Late Heading\n\n"

        let attributed = MarkdownSyntaxHighlighter().highlight(source, fileKind: .markdown)
        let inspected = NSAttributedString(attributed)

        let headingAttributes = try inspected.attributes(for: "Late Heading")
        let headingFont = try XCTUnwrap(headingAttributes[.font] as? NSFont)
        XCTAssertTrue(headingFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertGreaterThan(headingFont.pointSize, MarkdownSyntaxHighlighter.defaultFont.pointSize)
    }
}

private extension NSAttributedString {
    func attributes(for substring: String) throws -> [NSAttributedString.Key: Any] {
        let range = (string as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected to find substring '\(substring)'")
        return attributes(at: range.location, effectiveRange: nil)
    }
}

private extension MarkdownSyntaxHighlighterTests {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private extension [MarkdownSyntaxToken] {
    var containsTSXToken: Bool {
        contains { $0.kind.isTSXToken }
    }

    func contains(kind: MarkdownSyntaxToken.Kind) -> Bool {
        contains { $0.kind == kind }
    }

    func kinds(in source: String, for substring: String) -> [MarkdownSyntaxToken.Kind] {
        let range = (source as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected to find substring '\(substring)'")

        return filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.kind)
    }

    func ranges(kind: MarkdownSyntaxToken.Kind) -> [NSRange] {
        filter { $0.kind == kind }
            .map(\.range)
            .sorted { lhs, rhs in
                if lhs.location != rhs.location {
                    return lhs.location < rhs.location
                }
                return lhs.length < rhs.length
            }
    }

    var tsxTokens: [MarkdownSyntaxToken] {
        filter(\.kind.isTSXToken)
            .sorted { lhs, rhs in
                if lhs.range.location != rhs.range.location {
                    return lhs.range.location < rhs.range.location
                }
                return lhs.range.length < rhs.range.length
            }
    }
}

private extension XCTestCase {
    func assertNoOverlappingTSXTokens(
        _ tokens: [MarkdownSyntaxToken],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sortedTokens = tokens.tsxTokens
        for (previous, current) in zip(sortedTokens, sortedTokens.dropFirst()) {
            XCTAssertLessThanOrEqual(NSMaxRange(previous.range), current.range.location, file: file, line: line)
        }
    }
}

private extension String {
    func ranges(of substring: String) -> [NSRange] {
        let nsString = self as NSString
        var ranges: [NSRange] = []
        var searchLocation = 0

        while searchLocation < nsString.length {
            let searchRange = NSRange(location: searchLocation, length: nsString.length - searchLocation)
            let range = nsString.range(of: substring, options: [], range: searchRange)
            guard range.location != NSNotFound else {
                break
            }
            ranges.append(range)
            searchLocation = NSMaxRange(range)
        }

        return ranges
    }
}

private extension MarkdownSyntaxToken.Kind {
    var isTSXToken: Bool {
        switch self {
        case .tsxKeyword, .tsxString, .tsxTag, .tsxAttribute, .tsxPunctuation:
            true
        default:
            false
        }
    }
}
