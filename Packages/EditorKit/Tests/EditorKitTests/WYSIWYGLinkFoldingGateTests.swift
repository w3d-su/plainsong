import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

@MainActor
final class WYSIWYGLinkFoldingGateTests: XCTestCase {
    func testL1InlineLinkFoldsExactChromeAndRevealTouchesOnlySelectedLink() throws {
        let source = "Read [one](https://one.example) and [two](https://two.example)."
        let folded = try applyLinkPresentation(
            source,
            selection: NSRange(location: (source as NSString).length, length: 0)
        )
        let links = try linkRegions(in: folded.presentation)

        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(source.substring(with: links[0].contentRange), "one")
        XCTAssertEqual(source.substrings(with: links[0].foldRanges), ["[", "](https://one.example)"])
        XCTAssertEqual(source.substring(with: links[1].contentRange), "two")
        XCTAssertEqual(source.substrings(with: links[1].foldRanges), ["[", "](https://two.example)"])
        assertFoldState(in: folded.textStorage, ranges: links.flatMap(\.foldRanges), isFolded: true)
        assertFoldState(
            in: folded.textStorage,
            ranges: links.map(\.contentRange),
            isFolded: false
        )

        let revealed = try applyLinkPresentation(
            source,
            selection: NSRange(location: source.nsRange(of: "one").location, length: 0)
        )
        let revealedLinks = try linkRegions(in: revealed.presentation)

        XCTAssertTrue(revealedLinks[0].isRevealed)
        XCTAssertFalse(revealedLinks[1].isRevealed)
        assertFoldState(in: revealed.textStorage, ranges: revealedLinks[0].foldRanges, isFolded: false)
        assertFoldState(in: revealed.textStorage, ranges: revealedLinks[1].foldRanges, isFolded: true)
    }

    func testL1NestedEmphasisInsideLinkFoldsAndRevealsWithoutRangeDrift() throws {
        let source = "Read [**bold** link](https://example.com) now."
        let folded = try applyLinkPresentation(source, selection: NSRange(location: 0, length: 0))
        let plan = try XCTUnwrap(folded.presentation.foldPlan)
        let link = try plan.onlyRegion(kind: .link)
        let strong = try plan.onlyRegion(kind: .strong)

        XCTAssertEqual(link.contentRange, source.nsRange(of: "**bold** link"))
        XCTAssertEqual(source.substrings(with: link.foldRanges), ["[", "](https://example.com)"])
        XCTAssertEqual(strong.contentRange, source.nsRange(of: "bold"))
        XCTAssertEqual(source.substrings(with: strong.foldRanges), ["**", "**"])
        assertFoldState(
            in: folded.textStorage,
            ranges: link.foldRanges + strong.foldRanges,
            isFolded: true
        )

        let revealed = try applyLinkPresentation(
            source,
            selection: NSRange(location: source.nsRange(of: "bold").location, length: 0)
        )
        let revealedPlan = try XCTUnwrap(revealed.presentation.foldPlan)
        let revealedLink = try revealedPlan.onlyRegion(kind: .link)
        let revealedStrong = try revealedPlan.onlyRegion(kind: .strong)

        XCTAssertEqual(revealedLink.contentRange, link.contentRange)
        XCTAssertEqual(revealedStrong.contentRange, strong.contentRange)
        XCTAssertTrue(revealedLink.isRevealed)
        XCTAssertTrue(revealedStrong.isRevealed)
        assertFoldState(
            in: revealed.textStorage,
            ranges: revealedLink.foldRanges + revealedStrong.foldRanges,
            isFolded: false
        )
    }

    func testL1ReferenceLinksAutolinksAndImagesStayRaw() throws {
        let source = "[inline](destination) [reference][ref] <https://example.com> ![alt](image.png)"
        let result = try applyLinkPresentation(
            source,
            selection: NSRange(location: (source as NSString).length, length: 0)
        )
        let link = try XCTUnwrap(try linkRegions(in: result.presentation).only)

        XCTAssertEqual(link.sourceRange, source.nsRange(of: "[inline](destination)"))
        assertFoldState(in: result.textStorage, ranges: link.foldRanges, isFolded: true)
        for rawConstruct in ["[reference][ref]", "<https://example.com>", "![alt](image.png)"] {
            assertFoldState(
                in: result.textStorage,
                ranges: [source.nsRange(of: rawConstruct)],
                isFolded: false
            )
        }
    }

    func testL2FoldedLinkUsesThemeStylingWithoutSyntheticCharacters() throws {
        let source = "Read [styled link](https://example.com) now."
        let result = try applyLinkPresentation(source, selection: NSRange(location: 0, length: 0))
        let link = try XCTUnwrap(try linkRegions(in: result.presentation).only)
        let attributes = result.textStorage.attributes(at: link.contentRange.location, effectiveRange: nil)

        XCTAssertEqual(attributes[.foregroundColor] as? NSColor, MarkdownSyntaxTheme.standard.linkColor)
        XCTAssertEqual(attributes[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertNil(attributes[.attachment])
        XCTAssertEqual(result.textStorage.string, source)
        XCTAssertFalse(result.textStorage.string.contains("\u{FFFC}"))

        let textContentStorage = try XCTUnwrap(result.textView.textContentManager as? NSTextContentStorage)
        let zeroWidthDelegate = try XCTUnwrap(
            textContentStorage.delegate as? WYSIWYGZeroWidthTextContentStorageDelegate
        )
        let paragraphRange = (source as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let paragraph = try XCTUnwrap(
            zeroWidthDelegate.textContentStorage(textContentStorage, textParagraphWith: paragraphRange)
        )
        let projected = paragraph.attributedString.string as NSString

        XCTAssertEqual(projected.length, (source as NSString).length)
        XCTAssertEqual(projected.substring(with: link.contentRange), "styled link")
        for foldedRange in link.foldRanges {
            XCTAssertEqual(
                projected.substring(with: foldedRange),
                String(repeating: "\u{200B}", count: foldedRange.length)
            )
        }
    }

    func testL2LinkFoldingRemainsOffWithoutSubgateOptIn() throws {
        let source = "Read [link](https://example.com)."
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length),
            developmentPresentation: .inlineFoldReveal,
            selection: NSRange(location: 0, length: 0)
        )
        let plan = try XCTUnwrap(highlighted.foldPlan)
        let link = try plan.onlyRegion(kind: .link)
        let attributed = NSMutableAttributedString(attributedString: NSAttributedString(highlighted.text))
        WYSIWYGInlineFoldPresentation.applyFoldedDelimiterAttributes(
            plan: plan,
            visibleRange: highlighted.range,
            to: attributed
        )

        XCTAssertFalse(plan.linkFoldingEnabled)
        assertFoldState(in: attributed, ranges: link.foldRanges, isFolded: false)
    }
}

@MainActor
private extension WYSIWYGLinkFoldingGateTests {
    struct AppliedPresentation {
        let textView: MarkdownSTTextView
        let textStorage: NSTextStorage
        let presentation: MarkdownHighlightResult
    }

    func applyLinkPresentation(_ source: String, selection: NSRange) throws -> AppliedPresentation {
        let textView = MarkdownSTTextView(frame: .zero)
        textView.font = MarkdownSyntaxHighlighter.defaultFont
        textView.text = source
        textView.textSelection = selection
        XCTAssertTrue(textView.setWYSIWYGZeroWidthFoldingEnabled(true))

        let presentation = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length),
            developmentPresentation: .inlineFoldRevealWithLinkFolding,
            selection: selection
        )
        XCTAssertTrue(MarkdownTextView.applyHighlightedText(
            HighlightedText(
                revision: 1,
                range: presentation.range,
                text: presentation.text,
                foldPlan: presentation.foldPlan
            ),
            to: textView
        ))

        return try AppliedPresentation(
            textView: textView,
            textStorage: XCTUnwrap(MarkdownTextView.textStorage(of: textView)),
            presentation: presentation
        )
    }

    func linkRegions(in presentation: MarkdownHighlightResult) throws -> [WYSIWYGFoldRegion] {
        try XCTUnwrap(presentation.foldPlan).regions.filter { $0.kind == .link }
    }

    func assertFoldState(
        in attributed: NSAttributedString,
        ranges: [NSRange],
        isFolded: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for range in ranges {
            let attributes = attributed.attributes(at: range.location, effectiveRange: nil)
            XCTAssertEqual(
                WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(attributes),
                isFolded,
                "Unexpected fold state for \(range)",
                file: file,
                line: line
            )
        }
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}

private extension WYSIWYGFoldPlan {
    func onlyRegion(
        kind: WYSIWYGFoldRegion.Kind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> WYSIWYGFoldRegion {
        let matching = regions.filter { $0.kind == kind }
        XCTAssertEqual(matching.count, 1, file: file, line: line)
        return try XCTUnwrap(matching.first, file: file, line: line)
    }
}

private extension String {
    func nsRange(of substring: String) -> NSRange {
        let range = (self as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected to find '\(substring)'")
        return range
    }

    func substring(with range: NSRange) -> String {
        (self as NSString).substring(with: range)
    }

    func substrings(with ranges: [NSRange]) -> [String] {
        ranges.map { substring(with: $0) }
    }
}
