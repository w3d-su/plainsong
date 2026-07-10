import Foundation
@testable import MarkdownCore
import XCTest

final class MarkdownImageRegionsTests: XCTestCase {
    func testInlineImageRegionsRoundTripExactUTF16Ranges() throws {
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
                name: "image title",
                source: "![caption](assets/photo.webp \"cover photo\")",
                images: [.init(
                    "![caption](assets/photo.webp \"cover photo\")",
                    alt: "caption",
                    path: "assets/photo.webp",
                    title: "\"cover photo\""
                )]
            ),
            ImageDocumentCase(
                name: "multiple images on one line",
                source: "![first](one.png) then ![second](two.gif)",
                images: [
                    .init("![first](one.png)", alt: "first", path: "one.png"),
                    .init("![second](two.gif)", alt: "second", path: "two.gif"),
                ]
            ),
            ImageDocumentCase(
                name: "heading list and emphasis",
                source: "# ![heading](heading.jpg)\n- *![emphasis](emphasis.webp)*\n",
                images: [
                    .init("![heading](heading.jpg)", alt: "heading", path: "heading.jpg"),
                    .init("![emphasis](emphasis.webp)", alt: "emphasis", path: "emphasis.webp"),
                ]
            ),
            ImageDocumentCase(
                name: "CRLF document",
                source: "Before\r\n![line](line.gif \"title\")\r\nAfter\r\n",
                images: [.init(
                    "![line](line.gif \"title\")",
                    alt: "line",
                    path: "line.gif",
                    title: "\"title\""
                )]
            ),
            ImageDocumentCase(
                name: "CJK and emoji",
                source: "開頭😀 ![替代🐱](資產/照片🌄.JPEG \"標題✨\") 結尾",
                images: [.init(
                    "![替代🐱](資產/照片🌄.JPEG \"標題✨\")",
                    alt: "替代🐱",
                    path: "資產/照片🌄.JPEG",
                    title: "\"標題✨\""
                )]
            ),
        ]

        for testCase in cases {
            let storage = testCase.source as NSString
            var searchLocation = 0

            for image in testCase.images {
                let sourceRange = storage.range(
                    of: image.literal,
                    options: [],
                    range: NSRange(location: searchLocation, length: storage.length - searchLocation)
                )
                XCTAssertNotEqual(sourceRange.location, NSNotFound, testCase.name)
                searchLocation = NSMaxRange(sourceRange)

                let altTextRange = NSRange(
                    location: sourceRange.location + 2,
                    length: image.alt.utf16.count
                )
                let sourcePathRange = NSRange(
                    location: NSMaxRange(altTextRange) + 2,
                    length: image.path.utf16.count
                )
                let titleRange = image.title.map {
                    NSRange(location: NSMaxRange(sourcePathRange) + 1, length: $0.utf16.count)
                }
                let region = try XCTUnwrap(MarkdownInlineImageRegion(
                    in: testCase.source,
                    sourceRange: sourceRange,
                    altTextRange: altTextRange,
                    sourcePathRange: sourcePathRange,
                    titleRange: titleRange
                ), testCase.name)

                XCTAssertEqual(storage.substring(with: region.sourceRange), image.literal, testCase.name)
                XCTAssertEqual(storage.substring(with: region.altTextRange), image.alt, testCase.name)
                XCTAssertEqual(storage.substring(with: region.sourcePathRange), image.path, testCase.name)
                XCTAssertEqual(region.titleRange.map(storage.substring(with:)), image.title, testCase.name)
                XCTAssertEqual(storage.substring(with: region.openingChromeRange), "![", testCase.name)
                XCTAssertEqual(storage.substring(with: region.separatorChromeRange), "](", testCase.name)
                XCTAssertEqual(storage.substring(with: region.closingChromeRange), ")", testCase.name)
            }
        }
    }

    func testInlineImageRegionRejectsReferenceAutolinkEmptySourceAndMalformedForms() {
        let cases = [
            UnsupportedImageCase(
                source: "![alt][ref]",
                altLength: 3,
                sourcePathRange: NSRange(location: 7, length: 3)
            ),
            UnsupportedImageCase(
                source: "![alt](<https://example.com/image.png>)",
                altLength: 3,
                sourcePathRange: NSRange(location: 7, length: 31)
            ),
            UnsupportedImageCase(
                source: "![alt](<local.png>)",
                altLength: 3,
                sourcePathRange: NSRange(location: 7, length: 11)
            ),
            UnsupportedImageCase(
                source: "![alt]()",
                altLength: 3,
                sourcePathRange: NSRange(location: 7, length: 0)
            ),
            UnsupportedImageCase(
                source: "![alt](path.png 'single')",
                altLength: 3,
                sourcePathRange: NSRange(location: 7, length: 8),
                titleRange: NSRange(location: 16, length: 8)
            ),
            UnsupportedImageCase(
                source: "![alt](path.png \"unclosed)",
                altLength: 3,
                sourcePathRange: NSRange(location: 7, length: 8),
                titleRange: NSRange(location: 16, length: 9)
            ),
        ]

        for testCase in cases {
            let storage = testCase.source as NSString
            let sourceRange = NSRange(location: 0, length: storage.length)
            let altTextRange = NSRange(location: 2, length: testCase.altLength)
            XCTAssertNil(MarkdownInlineImageRegion(
                in: testCase.source,
                sourceRange: sourceRange,
                altTextRange: altTextRange,
                sourcePathRange: testCase.sourcePathRange,
                titleRange: testCase.titleRange
            ), testCase.source)
        }
    }

    func testThumbnailEligibilityAllowsSharedRasterExtensions() {
        let maximum = MarkdownImageAssetPolicy.maximumFileSizeBytes
        assertThumbnailEligibility([
            (
                "allowlisted extension is lowercased",
                workspaceSource(source: "assets/photo.PNG", path: "assets/photo.PNG", bytes: maximum),
                .thumbnailEligible
            ),
            (
                "jpeg is allowlisted",
                workspaceSource(source: "assets/photo.jpeg", path: "assets/photo.jpeg", bytes: 1),
                .thumbnailEligible
            ),
            (
                "jpg is allowlisted",
                workspaceSource(source: "assets/photo.jpg", path: "assets/photo.jpg", bytes: 1),
                .thumbnailEligible
            ),
            (
                "gif is allowlisted",
                workspaceSource(source: "assets/photo.gif", path: "assets/photo.gif", bytes: 1),
                .thumbnailEligible
            ),
            (
                "webp is allowlisted",
                workspaceSource(source: "assets/photo.webp", path: "assets/photo.webp", bytes: 1),
                .thumbnailEligible
            ),
        ])
    }

    func testThumbnailEligibilityRejectsIneligibleSources() {
        let maximum = MarkdownImageAssetPolicy.maximumFileSizeBytes
        assertThumbnailEligibility([
            (
                "HTTP stays raw",
                workspaceSource(source: "http://example.com/photo.png", path: nil, bytes: nil),
                .stayRaw(.remoteHTTPSource(scheme: "http"))
            ),
            (
                "HTTPS stays raw",
                workspaceSource(source: "https://example.com/photo.png", path: nil, bytes: nil),
                .stayRaw(.remoteHTTPSource(scheme: "https"))
            ),
            (
                "data stays raw",
                workspaceSource(source: "data:image/png;base64,AAAA", path: nil, bytes: nil),
                .stayRaw(.dataSource)
            ),
            (
                "file URL stays raw",
                workspaceSource(source: "file:///tmp/photo.png", path: nil, bytes: nil),
                .stayRaw(.fileSource)
            ),
            (
                "other source scheme stays raw",
                workspaceSource(source: "ftp://example.com/photo.png", path: nil, bytes: nil),
                .stayRaw(.unsupportedSourceScheme("ftp"))
            ),
            (
                "SVG stays raw",
                workspaceSource(source: "assets/vector.svg", path: "assets/vector.svg", bytes: 1),
                .stayRaw(.unsupportedPathExtension("svg"))
            ),
            (
                "oversized stays raw",
                workspaceSource(source: "assets/large.webp", path: "assets/large.webp", bytes: maximum + 1),
                .stayRaw(.fileTooLarge(actualBytes: maximum + 1, maximumBytes: maximum))
            ),
            (
                "outside workspace stays raw",
                MarkdownImageWorkspaceSource(
                    source: "../outside.png",
                    resolvedWorkspaceRelativePath: nil,
                    fileByteCount: 1,
                    isInsideWorkspaceRoot: false,
                    hasDirectoryScope: true
                ),
                .stayRaw(.outsideWorkspace)
            ),
            (
                "single file mode stays raw",
                MarkdownImageWorkspaceSource(
                    source: "sibling.png",
                    resolvedWorkspaceRelativePath: nil,
                    fileByteCount: 1,
                    isInsideWorkspaceRoot: true,
                    hasDirectoryScope: false
                ),
                .stayRaw(.noDirectoryScope)
            ),
            (
                "unresolved workspace path stays raw",
                workspaceSource(source: "missing.png", path: nil, bytes: 1),
                .stayRaw(.unresolvedWorkspacePath)
            ),
            (
                "missing size stays raw",
                workspaceSource(source: "assets/missing-size.png", path: "assets/missing-size.png", bytes: nil),
                .stayRaw(.missingFileSize)
            ),
            (
                "empty source stays raw",
                workspaceSource(source: "", path: "assets/photo.png", bytes: 1),
                .stayRaw(.emptySource)
            ),
        ])
    }

    func testThumbnailEligibilityIsDeterministicForIdenticalInputs() {
        let source = workspaceSource(
            source: "assets/照片.webp",
            path: "assets/照片.webp",
            bytes: MarkdownImageAssetPolicy.maximumFileSizeBytes
        )

        XCTAssertEqual(
            MarkdownImageThumbnailPolicy.eligibility(for: source),
            MarkdownImageThumbnailPolicy.eligibility(for: source)
        )
    }
}

private extension MarkdownImageRegionsTests {
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

    struct UnsupportedImageCase {
        let source: String
        let altLength: Int
        let sourcePathRange: NSRange
        let titleRange: NSRange?

        init(
            source: String,
            altLength: Int,
            sourcePathRange: NSRange,
            titleRange: NSRange? = nil
        ) {
            self.source = source
            self.altLength = altLength
            self.sourcePathRange = sourcePathRange
            self.titleRange = titleRange
        }
    }

    func workspaceSource(
        source: String,
        path: String?,
        bytes: Int64?
    ) -> MarkdownImageWorkspaceSource {
        MarkdownImageWorkspaceSource(
            source: source,
            resolvedWorkspaceRelativePath: path,
            fileByteCount: bytes,
            isInsideWorkspaceRoot: true,
            hasDirectoryScope: true
        )
    }

    func assertThumbnailEligibility(
        _ cases: [(name: String, source: MarkdownImageWorkspaceSource, expected: MarkdownImageThumbnailEligibility)]
    ) {
        for testCase in cases {
            XCTAssertEqual(
                MarkdownImageThumbnailPolicy.eligibility(for: testCase.source),
                testCase.expected,
                testCase.name
            )
        }
    }
}
