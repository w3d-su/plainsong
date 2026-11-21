import Foundation
import MarkdownCore
import SyntaxKit
import XCTest

final class SyntaxProviderCoverageTests: XCTestCase {
    func testProviderTokenizesTheCoverageItReportsWithoutASecondExpansion() async throws {
        let source = "---\ntitle: x\n---\n\n" + String(repeating: "filler **word**\n\n", count: 400)
            + "```swift\nlet a = 1\nlet b = 2\n```\n\n# tail\n"
        let visible = (source as NSString).range(of: "let b")
        let result = try await MarkdownSyntaxTokenizer().tokens(for: SyntaxRequest(
            requestID: UUID(),
            version: 1,
            source: source,
            fileKind: .markdown,
            visibleRange: visible
        ))
        let parser = try MarkdownSyntaxParser()

        XCTAssertEqual(
            result.coveredRange,
            MarkdownSyntaxParser.visibleHighlightRange(in: source, requestedRange: visible)
        )
        XCTAssertEqual(result.tokens, parser.tokens(in: source, fileKind: .markdown, visibleRange: visible))
        XCTAssertTrue(result.tokens.contains { $0.kind == .codeBlock })
        XCTAssertTrue(result.tokens.allSatisfy { NSIntersectionRange($0.range, result.coveredRange) == $0.range })
    }
}
