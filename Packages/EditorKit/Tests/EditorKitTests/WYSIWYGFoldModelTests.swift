@testable import EditorKit
import Foundation
import MarkdownCore
import XCTest

final class WYSIWYGFoldModelTests: XCTestCase {
    func testHeadingMarkerFoldsOutsideHeadingLineAndRevealsOnLine() throws {
        let source = "Intro\n## Heading\nOutro\n"
        let parser = try WYSIWYGFoldParser()
        let fullRange = NSRange(location: 0, length: (source as NSString).length)

        let folded = parser.foldPlan(
            in: source,
            fileKind: .markdown,
            visibleRange: fullRange,
            selection: source.range(of: "Intro")
        )

        let foldedHeading = try folded.onlyRegion(kind: .heading(level: 2))
        XCTAssertEqual(foldedHeading.contentRange, source.range(of: "Heading"))
        XCTAssertEqual(foldedHeading.foldRanges, [source.range(of: "## ")])
        XCTAssertFalse(foldedHeading.isRevealed)
        XCTAssertEqual(folded.foldedRanges, [source.range(of: "## ")])

        let revealed = parser.foldPlan(
            in: source,
            fileKind: .markdown,
            visibleRange: fullRange,
            selection: NSRange(location: source.range(of: "Heading").location, length: 0)
        )

        let revealedHeading = try revealed.onlyRegion(kind: .heading(level: 2))
        XCTAssertTrue(revealedHeading.isRevealed)
        XCTAssertEqual(revealed.foldedRanges, [])
    }

    func testInlineMarkupFoldsOnlyDelimitersOutsideSelection() throws {
        let source = "**bold** *em* ~~gone~~ `code`"
        let plan = try foldPlan(for: source, selection: NSRange(location: (source as NSString).length, length: 0))

        let strong = try plan.onlyRegion(kind: .strong)
        XCTAssertEqual(source.substring(with: strong.contentRange), "bold")
        XCTAssertEqual(source.substrings(with: strong.foldRanges), ["**", "**"])

        let emphasis = try plan.onlyRegion(kind: .emphasis)
        XCTAssertEqual(source.substring(with: emphasis.contentRange), "em")
        XCTAssertEqual(source.substrings(with: emphasis.foldRanges), ["*", "*"])

        let strike = try plan.onlyRegion(kind: .strikethrough)
        XCTAssertEqual(source.substring(with: strike.contentRange), "gone")
        XCTAssertEqual(source.substrings(with: strike.foldRanges), ["~~", "~~"])

        let code = try plan.onlyRegion(kind: .inlineCode)
        XCTAssertEqual(source.substring(with: code.contentRange), "code")
        XCTAssertEqual(source.substrings(with: code.foldRanges), ["`", "`"])
    }

    func testCaretInsideInlineSpanRevealsOnlyTouchedRegion() throws {
        let source = "**bold** and `code`"
        let plan = try foldPlan(for: source, selection: NSRange(location: source.range(of: "bold").location, length: 0))

        XCTAssertTrue(try plan.onlyRegion(kind: .strong).isRevealed)
        XCTAssertFalse(try plan.onlyRegion(kind: .inlineCode).isRevealed)
        XCTAssertEqual(source.substrings(with: plan.foldedRanges), ["`", "`"])
    }

    func testInlineRevealBoundaryDecisionsUseHalfOpenSourceRanges() throws {
        let source = "x **bold** y"
        let strongRange = source.range(of: "**bold**")

        XCTAssertFalse(try strongRegion(in: source, selection: source.range(of: "x ")).isRevealed)
        XCTAssertTrue(try strongRegion(
            in: source,
            selection: NSRange(location: strongRange.location, length: 0)
        ).isRevealed)
        XCTAssertTrue(try strongRegion(
            in: source,
            selection: NSRange(location: NSMaxRange(strongRange) - 1, length: 0)
        ).isRevealed)
        XCTAssertFalse(try strongRegion(
            in: source,
            selection: NSRange(location: NSMaxRange(strongRange), length: 0)
        ).isRevealed)
        XCTAssertFalse(try strongRegion(in: source, selection: source.range(of: " y")).isRevealed)
    }

    func testInlineRevealBoundaryDecisionsCoverEveryFoldedInlineKind() throws {
        let source = "x **bold** *em* ~~gone~~ `code` [docs](https://example.com)"
        let cases: [(kind: WYSIWYGFoldRegion.Kind, raw: String)] = [
            (.strong, "**bold**"),
            (.emphasis, "*em*"),
            (.strikethrough, "~~gone~~"),
            (.inlineCode, "`code`"),
            (.link, "[docs](https://example.com)"),
        ]

        for testCase in cases {
            let rawRange = source.range(of: testCase.raw)

            XCTAssertFalse(try region(
                kind: testCase.kind,
                in: source,
                selection: NSRange(location: max(0, rawRange.location - 1), length: 0)
            ).isRevealed)
            XCTAssertTrue(try region(
                kind: testCase.kind,
                in: source,
                selection: NSRange(location: rawRange.location, length: 0)
            ).isRevealed)
            XCTAssertTrue(try region(
                kind: testCase.kind,
                in: source,
                selection: NSRange(location: NSMaxRange(rawRange) - 1, length: 0)
            ).isRevealed)
            XCTAssertFalse(try region(
                kind: testCase.kind,
                in: source,
                selection: NSRange(location: NSMaxRange(rawRange), length: 0)
            ).isRevealed)
        }
    }

    func testAdjacentInlineRegionsRevealOnlyTheTouchedRegion() throws {
        let source = "**one** **two**"
        let plan = try foldPlan(for: source, selection: NSRange(location: source.range(of: "two").location, length: 0))
        let strongRegions = plan.regions.filter { $0.kind == .strong }
        XCTAssertEqual(strongRegions.count, 2)

        let first = try XCTUnwrap(strongRegions.first { $0.contentRange == source.range(of: "one") })
        let second = try XCTUnwrap(strongRegions.first { $0.contentRange == source.range(of: "two") })
        XCTAssertFalse(first.isRevealed)
        XCTAssertTrue(second.isRevealed)
        XCTAssertEqual(source.substrings(with: first.foldRanges), ["**", "**"])
    }

    func testNestedInlineRegionsRevealTouchedAncestorsAndDescendants() throws {
        let source = "**bold *italic* text**"
        let plan = try foldPlan(
            for: source,
            selection: NSRange(location: source.range(of: "italic").location, length: 0)
        )

        let strong = try plan.onlyRegion(kind: .strong)
        let emphasis = try plan.onlyRegion(kind: .emphasis)
        XCTAssertTrue(strong.isRevealed)
        XCTAssertTrue(emphasis.isRevealed)
        XCTAssertEqual(plan.foldedRanges, [])
    }

    func testHeadingRevealBoundaryDecisionsUseLineRange() throws {
        let source = "Intro\n## Heading\nOutro\n"
        let headingLine = source.lineRange(containing: "Heading")
        let headingText = source.range(of: "Heading")

        XCTAssertFalse(try headingRegion(in: source, selection: source.range(of: "Intro\n")).isRevealed)
        XCTAssertTrue(try headingRegion(
            in: source,
            selection: NSRange(location: headingLine.location, length: 0)
        ).isRevealed)
        XCTAssertTrue(try headingRegion(
            in: source,
            selection: NSRange(location: NSMaxRange(headingText), length: 0)
        ).isRevealed)
        XCTAssertFalse(try headingRegion(
            in: source,
            selection: NSRange(location: NSMaxRange(headingLine), length: 0)
        ).isRevealed)
    }

    func testSetextHeadingFoldsUnderlineAndRevealsAcrossHeadingLines() throws {
        let source = "Intro\n\nHeading\n=======\nOutro\n"
        let parser = try WYSIWYGFoldParser()
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        let folded = parser.foldPlan(
            in: source,
            fileKind: .markdown,
            visibleRange: fullRange,
            selection: source.range(of: "Outro")
        )

        let heading = try folded.onlyRegion(kind: .heading(level: 1))
        XCTAssertEqual(heading.contentRange, source.range(of: "Heading"))
        XCTAssertEqual(heading.foldRanges, [source.range(of: "=======")])
        XCTAssertFalse(heading.isRevealed)
        XCTAssertEqual(folded.foldedRanges, [source.range(of: "=======")])

        let revealed = parser.foldPlan(
            in: source,
            fileKind: .markdown,
            visibleRange: fullRange,
            selection: NSRange(location: source.range(of: "=======").location, length: 0)
        )

        XCTAssertTrue(try revealed.onlyRegion(kind: .heading(level: 1)).isRevealed)
        XCTAssertEqual(revealed.foldedRanges, [])
    }

    func testInlineLinkFoldsChromeAndDestinationAndRevealsFromDestination() throws {
        let source = #"Read [docs](https://example.com "title") now"#
        let folded = try foldPlan(for: source, selection: NSRange(location: 0, length: 0))

        let link = try folded.onlyRegion(kind: .link)
        XCTAssertEqual(source.substring(with: link.contentRange), "docs")
        XCTAssertEqual(source.substrings(with: link.foldRanges), ["[", #"](https://example.com "title")"#])
        XCTAssertFalse(link.isRevealed)

        let revealed = try foldPlan(
            for: source,
            selection: NSRange(location: source.range(of: "https://example.com").location, length: 0)
        )

        XCTAssertTrue(try revealed.onlyRegion(kind: .link).isRevealed)
        XCTAssertEqual(revealed.foldedRanges, [])
    }

    func testCJKSourceRangesStayUTF16Aligned() throws {
        let source = "# 中文標題\n\n前綴 **粗體文字** 和 [連結](https://example.com)\n"
        let plan = try foldPlan(for: source, selection: NSRange(location: (source as NSString).length, length: 0))

        XCTAssertEqual(try plan.onlyRegion(kind: .heading(level: 1)).contentRange, source.range(of: "中文標題"))
        XCTAssertEqual(try plan.onlyRegion(kind: .strong).contentRange, source.range(of: "粗體文字"))
        XCTAssertEqual(try plan.onlyRegion(kind: .link).contentRange, source.range(of: "連結"))
        XCTAssertEqual(
            source.substrings(with: plan.foldedRanges),
            ["# ", "**", "**", "[", "](https://example.com)"]
        )
    }

    func testVisibleRangeOnlyBuildsCandidatesForVisibleLines() throws {
        let source = "# Hidden Heading\n\nVisible **bold** and [link](https://example.com)\n"
        let parser = try WYSIWYGFoldParser()
        let visibleLine = source.range(of: "Visible")

        let plan = parser.foldPlan(
            in: source,
            fileKind: .markdown,
            visibleRange: visibleLine,
            selection: NSRange(location: 0, length: 0)
        )

        XCTAssertNil(plan.regions.first { $0.kind == .heading(level: 1) })
        XCTAssertEqual(try plan.onlyRegion(kind: .strong).contentRange, source.range(of: "bold"))
        XCTAssertEqual(try plan.onlyRegion(kind: .link).contentRange, source.range(of: "link"))
    }

    func testEscapedDelimitersDoNotProduceFoldRegions() throws {
        let source = #"Escaped \*not italic\* and \~\~not struck\~\~"#
        let plan = try foldPlan(for: source, selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(plan.regions, [])
        XCTAssertEqual(plan.foldedRanges, [])
    }

    func testFoldRangesStayUTF16AlignedForCJKInlineMarkup() throws {
        let cjkPrefix = "\u{6BB5}\u{843D}"
        let cjkStrongText = "\u{4E2D}\u{6587}\u{7C97}\u{9AD4}"
        let cjkTrailingText = "\u{7D50}\u{5C3E}"
        let cjkLinkText = "\u{9023}\u{7D50}"
        let source = "\(cjkPrefix)**\(cjkStrongText)**\(cjkTrailingText) [\(cjkLinkText)](https://example.com)"
        let plan = try foldPlan(for: source, selection: NSRange(location: (source as NSString).length, length: 0))

        let strong = try plan.onlyRegion(kind: .strong)
        XCTAssertEqual(strong.contentRange, source.range(of: cjkStrongText))
        XCTAssertEqual(source.substrings(with: strong.foldRanges), ["**", "**"])

        let link = try plan.onlyRegion(kind: .link)
        XCTAssertEqual(link.contentRange, source.range(of: cjkLinkText))
        XCTAssertEqual(source.substrings(with: link.foldRanges), ["[", "](https://example.com)"])
    }
}

private extension WYSIWYGFoldModelTests {
    func foldPlan(for source: String, selection: NSRange) throws -> WYSIWYGFoldPlan {
        let parser = try WYSIWYGFoldParser()
        return parser.foldPlan(
            in: source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length),
            selection: selection
        )
    }

    func strongRegion(in source: String, selection: NSRange) throws -> WYSIWYGFoldRegion {
        try foldPlan(for: source, selection: selection).onlyRegion(kind: .strong)
    }

    func region(
        kind: WYSIWYGFoldRegion.Kind,
        in source: String,
        selection: NSRange
    ) throws -> WYSIWYGFoldRegion {
        try foldPlan(for: source, selection: selection).onlyRegion(kind: kind)
    }

    func headingRegion(in source: String, selection: NSRange) throws -> WYSIWYGFoldRegion {
        try foldPlan(for: source, selection: selection).onlyRegion(kind: .heading(level: 2))
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

private extension String {
    func range(of substring: String) -> NSRange {
        let range = (self as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected to find substring '\(substring)'")
        return range
    }

    func substring(with range: NSRange) -> String {
        (self as NSString).substring(with: range)
    }

    func substrings(with ranges: [NSRange]) -> [String] {
        ranges.map { substring(with: $0) }
    }

    func lineRange(containing substring: String) -> NSRange {
        let substringRange = range(of: substring)
        return (self as NSString).lineRange(for: substringRange)
    }
}
