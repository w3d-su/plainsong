@testable import MarkdownCore
import XCTest

final class FileKindTests: XCTestCase {
    func testMarkdownExtensions() {
        XCTAssertEqual(FileKind(fileExtension: "md"), .markdown)
        XCTAssertEqual(FileKind(fileExtension: "MD"), .markdown)
        XCTAssertEqual(FileKind(fileExtension: "markdown"), .markdown)
    }

    func testMDXExtension() {
        XCTAssertEqual(FileKind(fileExtension: "mdx"), .mdx)
        XCTAssertEqual(FileKind(fileExtension: "MDX"), .mdx)
    }

    func testUnknownExtensions() {
        XCTAssertNil(FileKind(fileExtension: "txt"))
        XCTAssertNil(FileKind(fileExtension: ""))
    }

    func testURLInitializer() {
        XCTAssertEqual(FileKind(url: URL(fileURLWithPath: "/posts/hello.mdx")), .mdx)
        XCTAssertEqual(FileKind(url: URL(fileURLWithPath: "/posts/hello.md")), .markdown)
        XCTAssertNil(FileKind(url: URL(fileURLWithPath: "/posts/hello")))
    }
}
