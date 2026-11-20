import Foundation
import MarkdownCore
@testable import SyntaxKit
import XCTest

/// CRLF documents parse like their LF twins: frontmatter keys are highlighted and the
/// WYSIWYG parse range still grows to whole tables.
final class CRLFLineEndingTests: XCTestCase {
    private var parser: MarkdownSyntaxParser!

    override func setUpWithError() throws {
        parser = try MarkdownSyntaxParser()
    }

    func testFrontmatterKeysAreHighlightedWithCRLF() throws {
        let lf = "---\ntitle: Hello\ndraft: true\n---\n\n# Body\n"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")

        for source in [lf, crlf] {
            let text = source as NSString
            let keys = parser.tokens(in: source, fileKind: .markdown)
                .filter { $0.kind == .frontmatterKey }
                .map { text.substring(with: $0.range) }
            XCTAssertEqual(keys, ["title", "draft"])
        }
    }

    func testFrontmatterBodyExcludesTheClosingLineTerminator() throws {
        let body = try XCTUnwrap(parser.frontmatterBody(in: "---\r\ntitle: x\r\n---"))
        XCTAssertEqual(("---\r\ntitle: x\r\n---" as NSString).substring(with: body), "title: x")
        XCTAssertNil(parser.frontmatterBody(in: "---"))
    }

    func testViewportInsideALongCRLFTableSeesTheWholeTable() throws {
        let prose = Array(repeating: "Prose line that keeps the document long enough.", count: 200)
            .joined(separator: "\r\n")
        let rows = (0 ..< 300).map { "| row \($0) | value \($0 * 7) | note |" }
        let table = (["| Key | Value | Note |", "| --- | ---: | :-: |"] + rows).joined(separator: "\r\n")
        let source = prose + "\r\n\r\n" + table + "\r\n\r\n" + prose + "\r\n"
        let text = source as NSString
        let tableRange = text.range(of: table)

        for needle in ["| Key |", "| row 150 |", "| row 299 |"] {
            let plan = parser.visibleTokensAndFoldPlan(
                in: source,
                fileKind: .markdown,
                visibleRange: text.lineRange(for: text.range(of: needle)),
                selection: NSRange(location: 0, length: 0),
                tableRegionsEnabled: true
            ).foldPlan
            let region = try XCTUnwrap(plan.tableRegions.first, needle)
            XCTAssertEqual(region.sourceRange, tableRange, needle)
            XCTAssertEqual(region.rows.count, 302, needle)
        }
    }
}
