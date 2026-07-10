import AppKit
@testable import EditorKit
import MarkdownCore
import XCTest

@MainActor
final class WYSIWYGImageRegionModelTests: XCTestCase {
    func testI1SharedVisibleParserProducesExactImageRegionsWithoutPresentation() throws {
        let cases = [
            ImageDocumentCase(
                name: "plain image",
                source: "![alt](images/photo.png)",
                images: [.init("![alt](images/photo.png)", alt: "alt", path: "images/photo.png")]
            ),
            ImageDocumentCase(
                name: "empty alt remains supported",
                source: "![](src.png)",
                images: [.init("![](src.png)", alt: "", path: "src.png")]
            ),
            ImageDocumentCase(
                name: "double-quoted title keeps exact ranges",
                source: "![caption](assets/photo.webp \"cover photo\")",
                images: [.init(
                    "![caption](assets/photo.webp \"cover photo\")",
                    alt: "caption",
                    path: "assets/photo.webp",
                    title: "\"cover photo\""
                )]
            ),
            ImageDocumentCase(
                name: "heading list emphasis multiple CRLF and unicode",
                source: "# ![heading](heading.jpg)\r\n- *![替代🐱](資產/照片🌄.JPEG \"標題✨\")*\r\n![one](one.png) ![two](two.gif)",
                images: [
                    .init("![heading](heading.jpg)", alt: "heading", path: "heading.jpg"),
                    .init(
                        "![替代🐱](資產/照片🌄.JPEG \"標題✨\")",
                        alt: "替代🐱",
                        path: "資產/照片🌄.JPEG",
                        title: "\"標題✨\""
                    ),
                    .init("![one](one.png)", alt: "one", path: "one.png"),
                    .init("![two](two.gif)", alt: "two", path: "two.gif"),
                ]
            ),
        ]

        for testCase in cases {
            let highlighted = MarkdownSyntaxHighlighter().highlight(
                testCase.source,
                fileKind: .markdown,
                visibleRange: NSRange(location: 0, length: (testCase.source as NSString).length),
                developmentPresentation: .inlineFoldReveal,
                selection: NSRange(location: (testCase.source as NSString).length, length: 0)
            )
            let plan = try XCTUnwrap(highlighted.foldPlan, testCase.name)
            let attributed = NSAttributedString(highlighted.text)
            let storage = testCase.source as NSString

            XCTAssertEqual(plan.imageRegions.count, testCase.images.count, testCase.name)
            for (region, image) in zip(plan.imageRegions, testCase.images) {
                XCTAssertEqual(storage.substring(with: region.sourceRange), image.literal, testCase.name)
                XCTAssertEqual(storage.substring(with: region.altTextRange), image.alt, testCase.name)
                XCTAssertEqual(storage.substring(with: region.sourcePathRange), image.path, testCase.name)
                XCTAssertEqual(region.titleRange.map(storage.substring(with:)), image.title, testCase.name)
                XCTAssertEqual(storage.substring(with: region.openingChromeRange), "![", testCase.name)
                XCTAssertEqual(storage.substring(with: region.separatorChromeRange), "](", testCase.name)
                XCTAssertEqual(storage.substring(with: region.closingChromeRange), ")", testCase.name)
                assertRawPresentation(
                    in: attributed,
                    sourceRange: region.sourceRange,
                    document: testCase.source,
                    message: testCase.name
                )
            }
        }
    }

    func testI1ReferenceAutolinkEmptySourceAndMalformedFormsDoNotEmitImageRegions() throws {
        let cases = [
            "![reference][ref]",
            "![auto](<https://example.com/image.png>)",
            "![local](<assets/photo.png>)",
            "![empty]()",
            "![alt](path.png 'single')",
        ]

        for source in cases {
            let highlighted = MarkdownSyntaxHighlighter().highlight(
                source,
                fileKind: .markdown,
                visibleRange: NSRange(location: 0, length: (source as NSString).length),
                developmentPresentation: .inlineFoldReveal,
                selection: NSRange(location: (source as NSString).length, length: 0)
            )
            let plan = try XCTUnwrap(highlighted.foldPlan, source)
            XCTAssertTrue(plan.imageRegions.isEmpty, source)
            XCTAssertEqual(NSAttributedString(highlighted.text).string, source, source)
            // Image metadata is not promoted into fold candidates; images stay fully raw.
            XCTAssertFalse(plan.regions.contains(where: { region in
                (source as NSString).substring(with: region.sourceRange).contains("![")
            }), source)
        }
    }

    func testI1ImageRegionsDoNotReceiveFoldPresentationAttributes() throws {
        let source = "before ![alt](photo.png \"title\") after"
        let highlighted = MarkdownSyntaxHighlighter().highlight(
            source,
            fileKind: .markdown,
            visibleRange: NSRange(location: 0, length: (source as NSString).length),
            developmentPresentation: .inlineFoldRevealWithLinkFolding,
            selection: NSRange(location: (source as NSString).length, length: 0)
        )
        let plan = try XCTUnwrap(highlighted.foldPlan)
        XCTAssertEqual(plan.imageRegions.count, 1)
        let attributed = NSAttributedString(highlighted.text)
        assertRawPresentation(
            in: attributed,
            sourceRange: plan.imageRegions[0].sourceRange,
            document: source,
            message: "image presentation attributes must remain absent in I1"
        )
        XCTAssertFalse(plan.regions.contains(where: { $0.kind == .link }))
    }
}

private extension WYSIWYGImageRegionModelTests {
    struct ImageDocumentCase {
        let name: String
        let source: String
        let images: [ImageExpectation]
    }

    struct ImageExpectation {
        let literal: String
        let alt: String
        let path: String
        let title: String?

        init(_ literal: String, alt: String, path: String, title: String? = nil) {
            self.literal = literal
            self.alt = alt
            self.path = path
            self.title = title
        }
    }

    func assertRawPresentation(
        in attributed: NSAttributedString,
        sourceRange: NSRange,
        document: String,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(attributed.string, document, message, file: file, line: line)
        for offset in sourceRange.location ..< NSMaxRange(sourceRange) {
            let attributes = attributed.attributes(at: offset, effectiveRange: nil)
            XCTAssertFalse(
                WYSIWYGInlineFoldPresentation.containsFoldedDelimiterAttributes(attributes),
                message,
                file: file,
                line: line
            )
        }
    }
}
