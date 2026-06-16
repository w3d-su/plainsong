@testable import MarkdownCore
import XCTest

final class SmartPasteTests: XCTestCase {
    func testSingleURLDetectorAcceptsURLsAndRejectsPlainOrMultilineText() {
        XCTAssertTrue(SmartPaste.isSingleURL("https://example.com/post?tag=swift#section"))
        XCTAssertTrue(SmartPaste.isSingleURL("mailto:hello@example.com"))

        XCTAssertFalse(SmartPaste.isSingleURL(""))
        XCTAssertFalse(SmartPaste.isSingleURL("example.com"))
        XCTAssertFalse(SmartPaste.isSingleURL("not a url"))
        XCTAssertFalse(SmartPaste.isSingleURL("https://example.com\nhttps://example.org"))
        XCTAssertFalse(SmartPaste.isSingleURL("https://example.com trailing"))
        XCTAssertFalse(SmartPaste.isSingleURL("https://"))
    }

    func testLinkReplacementRequiresNonEmptySelectionAndSingleURL() {
        XCTAssertEqual(
            SmartPaste.linkReplacement(selection: "Selected text", url: "https://example.com"),
            "[Selected text](https://example.com)"
        )

        XCTAssertNil(SmartPaste.linkReplacement(selection: "", url: "https://example.com"))
        XCTAssertNil(SmartPaste.linkReplacement(selection: "Selected text", url: "plain text"))
    }

    func testImageInsertionTextUsesPlainRelativePath() {
        XCTAssertEqual(
            SmartPaste.imageInsertion(relativePath: "assets/hero.png"),
            "![](assets/hero.png)"
        )
    }

    func testImageInsertionQuotesRelativePathWithMarkdownDelimiters() {
        XCTAssertEqual(
            SmartPaste.imageInsertion(relativePath: "assets/My Photo (final).png"),
            "![](<assets/My Photo (final).png>)"
        )
    }
}
