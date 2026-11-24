import Foundation
import MarkdownCore
import SyntaxKit
import XCTest

final class WYSIWYGMDXFoldTests: XCTestCase {
    private let source = """
    import * as a from './x_y_z'
    export const b = `q` + _c_ * 2 * d

    export const meta = {
      title: '*starred*',
    }

    text *em* and `code`

    - export *item*

    """

    private func regions(fileKind: FileKind) throws -> [String] {
        let parser = try MarkdownSyntaxParser()
        let length = source.utf16.count
        let combined = parser.visibleTokensAndFoldPlan(
            in: source,
            fileKind: fileKind,
            visibleRange: NSRange(location: 0, length: length),
            selection: NSRange(location: length, length: 0)
        ).foldPlan.regions
        let plan = WYSIWYGFoldParser(parser: parser).foldPlan(
            in: source,
            fileKind: fileKind,
            visibleRange: NSRange(location: 0, length: length),
            selection: NSRange(location: length, length: 0)
        )
        XCTAssertEqual(plan.regions, combined)
        return combined.map { (source as NSString).substring(with: $0.sourceRange) }
    }

    func testMDXDoesNotFoldInlineMarkupInsideESMBlocks() throws {
        XCTAssertEqual(try regions(fileKind: .mdx), ["*em*", "`code`", "*item*"])
    }

    func testMarkdownStillFoldsTheSameLinesAsProse() throws {
        XCTAssertEqual(
            try regions(fileKind: .markdown),
            ["`q`", "_c_", "*starred*", "*em*", "`code`", "*item*"]
        )
    }
}
