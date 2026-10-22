import Foundation
import MarkdownCore
import SyntaxKit
import XCTest

final class SyntaxContractConsumerTests: XCTestCase {
    func testConsumerKeepsRequestIdentityVersionAndAbsoluteUTF16Coordinates() async throws {
        let source = "繁中 👩🏽‍💻\n# heading"
        let range = (source as NSString).range(of: "heading")
        let request = SyntaxRequest(
            requestID: UUID(), version: 7, source: source, fileKind: .markdown, visibleRange: range
        )
        let provider: any MarkdownSyntaxTokenizing = TokenDouble(range: range)
        let result = try await provider.tokens(for: request)
        XCTAssertEqual(result.requestID, request.requestID)
        XCTAssertEqual(result.version, 7)
        XCTAssertEqual(result.tokens, [MarkdownSyntaxToken(kind: .headingText(level: 1), range: range)])
        XCTAssertEqual((source as NSString).substring(with: result.tokens[0].range), "heading")
    }
}

private actor TokenDouble: MarkdownSyntaxTokenizing {
    let range: NSRange

    init(range: NSRange) {
        self.range = range
    }

    func tokens(for request: SyntaxRequest) async throws -> SyntaxResult {
        SyntaxResult(
            requestID: request.requestID, version: request.version, coveredRange: range,
            tokens: [MarkdownSyntaxToken(kind: .headingText(level: 1), range: range)]
        )
    }
}
