import Foundation
import MarkdownCore
import SyntaxKit
import XCTest

final class WYSIWYGLinkFoldTests: XCTestCase {
    private func linkRegion(in source: String) throws -> WYSIWYGFoldRegion? {
        try MarkdownSyntaxParser().visibleTokensAndFoldPlan(
            in: source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: source.utf16.count),
            selection: NSRange(location: source.utf16.count, length: 0),
            linkFoldingEnabled: true
        ).foldPlan.regions.first { $0.kind == .link }
    }

    func testEscapedClosingBracketAtTheEndOfLinkTextStaysVisible() throws {
        let source = "[a\\]](u)\n\ntail\n"
        let region = try XCTUnwrap(linkRegion(in: source))

        XCTAssertEqual(region.sourceRange, NSRange(location: 0, length: 8))
        XCTAssertEqual((source as NSString).substring(with: region.contentRange), "a\\]")
        XCTAssertEqual(region.foldRanges, [NSRange(location: 0, length: 1), NSRange(location: 4, length: 4)])
    }

    func testPlainLinkFoldsOnlyTheBracketsAndDestination() throws {
        let source = "[plain](url)\n\ntail\n"
        let region = try XCTUnwrap(linkRegion(in: source))

        XCTAssertEqual(region.contentRange, NSRange(location: 1, length: 5))
        XCTAssertEqual(region.foldRanges, [NSRange(location: 0, length: 1), NSRange(location: 6, length: 6)])
    }
}
