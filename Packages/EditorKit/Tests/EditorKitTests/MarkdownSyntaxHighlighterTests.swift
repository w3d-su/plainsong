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

    func testDevelopmentInlineFoldRevealFoldsIncludedConstructsAndDefersLinks() throws {
        let source = """
        # Heading

        > Quote

        - **bold** and *italic* with ~~gone~~, `code`, and [link](https://example.com)
        """

        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length),
            developmentPresentation: .inlineFoldReveal,
            selection: NSRange(location: (source as NSString).length, length: 0)
        )
        let inspected = NSAttributedString.materializedPresentation(highlighted)

        XCTAssertTrue(try inspected.hasFoldedDelimiterAttributes(at: source.nsRange(of: "#")))
        XCTAssertTrue(try inspected.hasFoldedDelimiterAttributes(at: source.nsRange(of: "**")))
        XCTAssertTrue(try inspected.hasFoldedDelimiterAttributes(at: source.nsRange(of: "*italic*", selecting: "*")))
        XCTAssertTrue(try inspected.hasFoldedDelimiterAttributes(at: source.nsRange(of: "~~gone~~", selecting: "~~")))
        XCTAssertTrue(try inspected.hasFoldedDelimiterAttributes(at: source.nsRange(of: "`code`", selecting: "`")))

        let strikeAttributes = try inspected.attributes(for: "gone")
        XCTAssertEqual(strikeAttributes[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)

        let quoteAttributes = try inspected.attributes(for: ">")
        XCTAssertNotNil(quoteAttributes[.foregroundColor])

        XCTAssertFalse(
            try inspected.hasFoldedDelimiterAttributes(at: source.nsRange(of: "[link]", selecting: "["))
        )
        XCTAssertNotNil(try inspected.attributes(for: "link")[.underlineStyle])
    }

    func testDevelopmentInlineFoldRevealRevealsTouchedRegionOnly() throws {
        let source = "**bold** and `code`"
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length),
            developmentPresentation: .inlineFoldReveal,
            selection: NSRange(location: source.nsRange(of: "bold").location, length: 0)
        )
        let inspected = NSAttributedString.materializedPresentation(highlighted)

        XCTAssertFalse(try inspected.hasFoldedDelimiterAttributes(at: source.nsRange(of: "**")))
        XCTAssertTrue(try inspected.hasFoldedDelimiterAttributes(at: source.nsRange(of: "`code`", selecting: "`")))
        let strong = try XCTUnwrap(try highlighted.foldPlan?.onlyRegion(kind: .strong))
        let inlineCode = try XCTUnwrap(try highlighted.foldPlan?.onlyRegion(kind: .inlineCode))
        XCTAssertTrue(strong.isRevealed)
        XCTAssertFalse(inlineCode.isRevealed)
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

    func testVisibleRangeMarkdownParsesInlineMarkupAboveFullDocumentInlineLimit() throws {
        let filler = String(repeating: "Plain paragraph without inline markup.\n", count: 8000)
        let source = """
        \(filler)
        Visible paragraph with **bold visible text** and [a link](https://example.com).
        """

        XCTAssertGreaterThan(source.utf8.count, MarkdownSyntaxParser.inlineParsingLimit)

        let visibleRange = (source as NSString).range(of: "Visible paragraph")
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: visibleRange
        )
        let inspected = NSAttributedString(highlighted.text)

        let boldFont = try XCTUnwrap(inspected.attributes(for: "bold visible text")[.font] as? NSFont)
        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertNotNil(try inspected.attributes(for: "a link")[.underlineStyle])
    }

    func testVisibleRangeMDXParsesTSXAboveFullDocumentInlineLimit() throws {
        let filler = String(repeating: "Plain paragraph without inline markup.\n", count: 8000)
        let source = """
        \(filler)
        <Hero title="Large document" />
        """

        XCTAssertGreaterThan(source.utf8.count, MarkdownSyntaxParser.inlineParsingLimit)

        let visibleRange = (source as NSString).range(of: "<Hero title")
        let tokens = try MarkdownSyntaxParser().tokens(in: source, fileKind: .mdx, visibleRange: visibleRange)

        XCTAssertFalse(tokens.contains(kind: .mdxSource))
        XCTAssertTrue(tokens.kinds(in: source, for: "Hero title").contains(.tsxTag))
        XCTAssertTrue(tokens.kinds(in: source, for: "title=").contains(.tsxAttribute))
        XCTAssertTrue(tokens.kinds(in: source, for: "\"Large document\"").contains(.tsxString))
    }

    func testVisibleRangeInsideFenceExpandsToFenceContext() throws {
        let source = """
        Intro

        ```swift
        let visible = true
        ```

        Outro
        """

        let visibleRange = (source as NSString).range(of: "let visible")
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: visibleRange
        )
        let inspected = NSAttributedString(highlighted.text)

        XCTAssertNotNil(try inspected.attributes(for: "let visible")[.backgroundColor])
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

    /// Kind, absolute UTF-16 range, order, fold region, and image region captured from the
    /// pre-move parser. `SYNTAX_CAPTURE_BASELINE=1` writes the snapshot; later runs compare.
    func testTokenAndFoldBaselineMatchesPreMoveParser() throws {
        let actual = try SyntaxBaselineRenderer().data()
        let url = Self.repoRoot.appending(path: "docs/ios/evidence/lane-02/pre-move-baseline.json")
        if ProcessInfo.processInfo.environment["SYNTAX_CAPTURE_BASELINE"] == "1" {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try actual.write(to: url)
            return
        }
        let expected = try Data(contentsOf: url)
        XCTAssertEqual(actual, expected)
    }
}

private extension NSAttributedString {
    static func materializedPresentation(_ highlighted: MarkdownHighlightResult) -> NSAttributedString {
        let attributed = NSMutableAttributedString(attributedString: NSAttributedString(highlighted.text))
        if let foldPlan = highlighted.foldPlan {
            WYSIWYGInlineFoldPresentation.applyFoldedDelimiterAttributes(
                plan: foldPlan,
                visibleRange: highlighted.range,
                to: attributed
            )
        }
        return attributed
    }

    func attributes(for substring: String) throws -> [NSAttributedString.Key: Any] {
        let range = (string as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected to find substring '\(substring)'")
        return attributes(at: range.location, effectiveRange: nil)
    }

    func hasFoldedDelimiterAttributes(at range: NSRange) throws -> Bool {
        XCTAssertNotEqual(range.location, NSNotFound)
        return WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(
            attributes(at: range.location, effectiveRange: nil)
        )
    }
}

private extension WYSIWYGFoldPlan {
    func onlyRegion(
        kind: WYSIWYGFoldRegion.Kind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> WYSIWYGFoldRegion {
        let matchingRegions = regions.filter { $0.kind == kind }
        XCTAssertEqual(matchingRegions.count, 1, file: file, line: line)
        return try XCTUnwrap(matchingRegions.first, file: file, line: line)
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
    func nsRange(of substring: String) -> NSRange {
        let range = (self as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected to find substring '\(substring)'")
        return range
    }

    func nsRange(of containingSubstring: String, selecting selectedSubstring: String) -> NSRange {
        let containerRange = nsRange(of: containingSubstring)
        let container = (self as NSString).substring(with: containerRange) as NSString
        let selectedRange = container.range(of: selectedSubstring)
        XCTAssertNotEqual(
            selectedRange.location,
            NSNotFound,
            "Expected substring '\(selectedSubstring)' in '\(containingSubstring)'"
        )
        return NSRange(location: containerRange.location + selectedRange.location, length: selectedRange.length)
    }

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

/// Shared snapshot shape for the pre-move Mac parser and the extracted SyntaxKit parser.
/// Both sides must build these cases in the same order and encode with sorted keys.
struct SyntaxBaselineRenderer {
    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document())
    }

    func document() throws -> SyntaxBaselineDocument {
        let parser = try MarkdownSyntaxParser()
        let folds = WYSIWYGFoldParser(parser: parser)
        return try SyntaxBaselineDocument(cases: cases().map { spec in
            let full = parser.tokens(in: spec.source, fileKind: spec.fileKind)
            let visible = parser.tokens(
                in: spec.source,
                fileKind: spec.fileKind,
                visibleRange: spec.visibleRange
            )
            let covered = MarkdownSyntaxParser.visibleHighlightRange(
                in: spec.source,
                requestedRange: spec.visibleRange
            )
            let plan = folds.foldPlan(
                in: spec.source,
                fileKind: spec.fileKind,
                visibleRange: spec.visibleRange,
                selection: spec.selection
            )
            return SyntaxBaselineCase(
                name: spec.name,
                fileKind: spec.fileKind.rawValue,
                visibleRequest: SyntaxBaselineRange(spec.visibleRange),
                selection: SyntaxBaselineRange(spec.selection),
                covered: SyntaxBaselineRange(covered),
                fullTokens: full.map(SyntaxBaselineToken.init),
                visibleTokens: visible.map(SyntaxBaselineToken.init),
                fold: SyntaxBaselineFold(plan)
            )
        })
    }

    func cases() throws -> [SyntaxBaselineSpec] {
        var specs: [SyntaxBaselineSpec] = []
        for (name, kind) in [
            ("kitchen-sink.md", FileKind.markdown),
            ("kitchen-sink.mdx", FileKind.mdx),
            ("product-page.mdx", FileKind.mdx),
        ] as [(String, FileKind)] {
            let source = try String(
                contentsOf: MarkdownSyntaxHighlighterTests.repoRoot.appending(path: "Fixtures/\(name)"),
                encoding: .utf8
            )
            let length = (source as NSString).length
            let middle = NSRange(location: length / 3, length: min(24, max(0, length - length / 3)))
            specs.append(SyntaxBaselineSpec(
                name: "fixture-full-\(name)",
                source: source,
                fileKind: kind,
                visibleRange: NSRange(location: 0, length: length),
                selection: NSRange(location: 0, length: 0)
            ))
            specs.append(SyntaxBaselineSpec(
                name: "fixture-viewport-\(name)",
                source: source,
                fileKind: kind,
                visibleRange: middle,
                selection: NSRange(location: middle.location + min(2, middle.length), length: 0)
            ))
        }

        let traditional = "標題繁中 👩🏽‍💻 組合e\u{0301}\n第二行\n"
        let traditionalLength = (traditional as NSString).length
        let emoji = (traditional as NSString).range(of: "👩🏽‍💻")
        specs.append(contentsOf: [
            spec(
                "unicode-full",
                traditional,
                .markdown,
                NSRange(location: 0, length: traditionalLength),
                NSRange(location: emoji.location, length: 0)
            ),
            spec(
                "unicode-viewport-emoji",
                traditional,
                .markdown,
                emoji,
                NSRange(location: emoji.location, length: emoji.length)
            ),
            spec(
                "crlf-fence",
                "```swift\r\nlet x = 1\r\n```\r\n",
                .markdown,
                NSRange(location: 8, length: 4),
                NSRange(location: 0, length: 0)
            ),
            spec(
                "yaml-viewport",
                "---\ntitle: 標題\n---\n\n# 後\n",
                .markdown,
                NSRange(location: 5, length: 6),
                NSRange(location: 0, length: 0)
            ),
            spec(
                "long-fence-viewport",
                "para\n\n```ts\n" + String(repeating: "const a = 1\n", count: 40) + "```\n\nafter\n",
                .markdown,
                NSRange(location: 80, length: 12),
                NSRange(location: 0, length: 0)
            ),
            spec(
                "tsx-viewport",
                "import Button from './Button'\n\n<Button title=\"標題\">child</Button>\n",
                .mdx,
                NSRange(location: 32, length: 20),
                NSRange(location: 40, length: 0)
            ),
            spec(
                "multiline-emphasis",
                "before **bold\nstill** after\n",
                .markdown,
                NSRange(location: 10, length: 8),
                NSRange(location: 12, length: 0)
            ),
            spec("empty", "", .markdown, NSRange(location: 0, length: 0), NSRange(location: 0, length: 0)),
            spec("eof-caret", "abc\n", .markdown, NSRange(location: 4, length: 0), NSRange(location: 4, length: 0)),
            spec(
                "out-of-range",
                traditional,
                .markdown,
                NSRange(location: 10000, length: 40),
                NSRange(location: 0, length: 0)
            ),
        ])
        return specs
    }

    private func spec(
        _ name: String,
        _ source: String,
        _ fileKind: FileKind,
        _ visibleRange: NSRange,
        _ selection: NSRange
    ) -> SyntaxBaselineSpec {
        SyntaxBaselineSpec(
            name: name,
            source: source,
            fileKind: fileKind,
            visibleRange: visibleRange,
            selection: selection
        )
    }
}

struct SyntaxBaselineSpec {
    var name: String
    var source: String
    var fileKind: FileKind
    var visibleRange: NSRange
    var selection: NSRange
}

struct SyntaxBaselineDocument: Codable, Equatable {
    var cases: [SyntaxBaselineCase]
}

struct SyntaxBaselineCase: Codable, Equatable {
    var name: String
    var fileKind: String
    var visibleRequest: SyntaxBaselineRange
    var selection: SyntaxBaselineRange
    var covered: SyntaxBaselineRange
    var fullTokens: [SyntaxBaselineToken]
    var visibleTokens: [SyntaxBaselineToken]
    var fold: SyntaxBaselineFold
}

struct SyntaxBaselineRange: Codable, Equatable {
    var location: Int
    var length: Int

    init(_ range: NSRange) {
        location = range.location
        length = range.length
    }
}

struct SyntaxBaselineToken: Codable, Equatable {
    var kind: String
    var location: Int
    var length: Int

    init(_ token: MarkdownSyntaxToken) {
        kind = Self.kindName(token.kind)
        location = token.range.location
        length = token.range.length
    }

    static func kindName(_ kind: MarkdownSyntaxToken.Kind) -> String {
        if case let .headingText(level) = kind {
            return "headingText:\(level)"
        }
        return blockKindName(kind) ?? inlineKindName(kind) ?? trailingKindName(kind)
    }

    private static func blockKindName(_ kind: MarkdownSyntaxToken.Kind) -> String? {
        switch kind {
        case .frontmatter: "frontmatter"
        case .frontmatterKey: "frontmatterKey"
        case .headingMarker: "headingMarker"
        case .listMarker: "listMarker"
        case .codeBlock: "codeBlock"
        case .codeFenceMarker: "codeFenceMarker"
        case .codeFenceInfo: "codeFenceInfo"
        default: nil
        }
    }

    private static func inlineKindName(_ kind: MarkdownSyntaxToken.Kind) -> String? {
        switch kind {
        case .inlineCode: "inlineCode"
        case .strong: "strong"
        case .emphasis: "emphasis"
        case .linkText: "linkText"
        case .linkDestination: "linkDestination"
        case .quoteMarker: "quoteMarker"
        default: nil
        }
    }

    private static func trailingKindName(_ kind: MarkdownSyntaxToken.Kind) -> String {
        switch kind {
        case .tableHeader: "tableHeader"
        case .tableDelimiter: "tableDelimiter"
        case .tablePipe: "tablePipe"
        case .mdxSource: "mdxSource"
        case .tsxKeyword: "tsxKeyword"
        case .tsxString: "tsxString"
        case .tsxTag: "tsxTag"
        case .tsxAttribute: "tsxAttribute"
        case .tsxPunctuation: "tsxPunctuation"
        default:
            preconditionFailure("baseline kind already encoded")
        }
    }
}

struct SyntaxBaselineFold: Codable, Equatable {
    var visibleLocation: Int
    var visibleLength: Int
    var linkFoldingEnabled: Bool
    var regions: [SyntaxBaselineRegion]
    var images: [SyntaxBaselineImage]

    init(_ plan: WYSIWYGFoldPlan) {
        visibleLocation = plan.visibleRange.location
        visibleLength = plan.visibleRange.length
        linkFoldingEnabled = plan.linkFoldingEnabled
        regions = plan.regions.map(SyntaxBaselineRegion.init)
        images = plan.imageRegions.map(SyntaxBaselineImage.init)
    }
}

struct SyntaxBaselineRegion: Codable, Equatable {
    var kind: String
    var source: SyntaxBaselineRange
    var content: SyntaxBaselineRange
    var reveal: SyntaxBaselineRange
    var folds: [SyntaxBaselineRange]
    var revealed: Bool

    init(_ region: WYSIWYGFoldRegion) {
        kind = switch region.kind {
        case let .heading(level): "heading:\(level)"
        case .strong: "strong"
        case .emphasis: "emphasis"
        case .strikethrough: "strikethrough"
        case .inlineCode: "inlineCode"
        case .link: "link"
        }
        source = SyntaxBaselineRange(region.sourceRange)
        content = SyntaxBaselineRange(region.contentRange)
        reveal = SyntaxBaselineRange(region.revealRange)
        folds = region.foldRanges.map(SyntaxBaselineRange.init)
        revealed = region.isRevealed
    }
}

struct SyntaxBaselineImage: Codable, Equatable {
    var source: SyntaxBaselineRange
    var alt: SyntaxBaselineRange
    var path: SyntaxBaselineRange
    var title: SyntaxBaselineRange?

    init(_ region: MarkdownInlineImageRegion) {
        source = SyntaxBaselineRange(region.sourceRange)
        alt = SyntaxBaselineRange(region.altTextRange)
        path = SyntaxBaselineRange(region.sourcePathRange)
        title = region.titleRange.map(SyntaxBaselineRange.init)
    }
}
