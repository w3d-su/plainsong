import AppKit
import MarkdownCore
@testable import PreviewKit
import XCTest

@MainActor
final class ExportHTMLTitleTests: XCTestCase {
    func testDocumentTitleUsesFrontmatterThenFirstHeadingThenUntitled() async throws {
        let support = ExportHTMLHostedTests()
        struct TitleCase {
            let text: String
            let kind: FileKind
            let title: String
        }
        let cases: [TitleCase] = [
            .init(
                text: "---\ntitle: Frontmatter Title\n---\n\nParagraph\n\n## Body Heading",
                kind: .markdown,
                title: "Frontmatter Title"
            ),
            .init(text: "Paragraph\n\n## First H2\n\n# Later H1", kind: .markdown, title: "First H2"),
            .init(
                text: "<Card>\n\n# Card Heading\n\n</Card>\n\n## Document Heading",
                kind: .mdx,
                title: "Document Heading"
            ),
            .init(text: "No heading", kind: .markdown, title: "Untitled"),
        ]
        for item in cases {
            let controller = try support.makeController()
            let renderID = try await support.render(controller, text: item.text, fileKind: item.kind, version: 0)
            let result = await controller.exportHTML(matchingRenderID: renderID)
            controller.invalidate()
            guard case let .ready(html, _, _) = result else { return XCTFail("Expected ready: \(result)") }
            XCTAssertTrue(html.contains("<title>\(item.title)</title>"), "Wrong title for \(item.text)")
        }
    }
}
