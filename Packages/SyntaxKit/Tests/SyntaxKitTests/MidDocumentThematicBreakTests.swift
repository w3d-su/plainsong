import Foundation
import MarkdownCore
import SyntaxKit
import XCTest

/// A viewport whose first line is a `---` or `+++` thematic break is not frontmatter.
final class MidDocumentThematicBreakTests: XCTestCase {
    private func source(marker: String) -> (text: String, breakLocation: Int) {
        let prefix = String(repeating: "paragraph\n\n", count: 5)
        let body = "\(marker)\n\n# Heading **bold**\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\n\(marker)\n\ntail *em*\n"
        return (prefix + body, prefix.utf16.count)
    }

    func testVisibleTokensKeepMarkdownBetweenTwoThematicBreaks() throws {
        let parser = try MarkdownSyntaxParser()
        for marker in ["---", "+++"] {
            let (text, location) = source(marker: marker)
            let visible = NSRange(location: location, length: 10)
            XCTAssertEqual(
                MarkdownSyntaxParser.visibleHighlightRange(in: text, requestedRange: visible).location,
                location
            )

            let tokens = parser.tokens(in: text, fileKind: .markdown, visibleRange: visible)
            let full = parser.tokens(in: text, fileKind: .markdown).filter { $0.range.location >= location }

            XCTAssertFalse(tokens.contains { $0.kind == .frontmatter }, marker)
            XCTAssertEqual(tokens, full, marker)
            XCTAssertTrue(tokens.contains { $0.kind == .headingText(level: 1) }, marker)
        }
    }

    func testFoldPlanKeepsFoldsAndTablesBetweenTwoThematicBreaks() throws {
        let parser = try MarkdownSyntaxParser()
        let (text, location) = source(marker: "---")
        let nsText = text as NSString
        let visible = NSRange(location: location, length: 10)

        let result = parser.visibleTokensAndFoldPlan(
            in: text,
            fileKind: .markdown,
            visibleRange: visible,
            selection: NSRange(location: 0, length: 0),
            tableRegionsEnabled: true
        )
        XCTAssertFalse(result.tokens.contains { $0.kind == .frontmatter })
        XCTAssertEqual(
            result.foldPlan.regions.first { $0.kind == .strong }?.sourceRange,
            nsText.range(of: "**bold**")
        )
        XCTAssertEqual(result.foldPlan.tableRegions.count, 1)
        XCTAssertEqual(result.foldPlan.tableRegions.first?.sourceRange.location, nsText.range(of: "| a |").location)

        let plan = WYSIWYGFoldParser(parser: parser).foldPlan(
            in: text,
            fileKind: .markdown,
            visibleRange: visible,
            selection: NSRange(location: 0, length: 0),
            tableRegionsEnabled: true
        )
        XCTAssertEqual(plan.regions, result.foldPlan.regions)
        XCTAssertEqual(plan.tableRegions, result.foldPlan.tableRegions)
    }

    func testLeadingFrontmatterIsStillFrontmatter() throws {
        let text = "---\ntitle: x\n---\n\n# Heading\n"
        let tokens = try MarkdownSyntaxParser().tokens(
            in: text,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: 5)
        )
        XCTAssertEqual(tokens.first { $0.kind == .frontmatter }?.range, NSRange(location: 0, length: 17))
        XCTAssertTrue(tokens.contains { $0.kind == .frontmatterKey })
    }
}
