@testable import MarkdownCore
import XCTest

@MainActor
final class DocumentSessionRelocationTests: XCTestCase {
    func testRelocatePreservesSavedBaselineAndDirtyState() {
        let oldURL = URL(fileURLWithPath: "/tmp/old.md")
        let newURL = URL(fileURLWithPath: "/tmp/new.md")
        let session = DocumentSession(text: "Original", url: oldURL, fileKind: .markdown)
        session.replaceText("Changed")
        let editedVersion = session.version

        session.relocate(to: newURL)

        XCTAssertEqual(session.fileURL, newURL)
        XCTAssertEqual(session.text, "Changed")
        XCTAssertEqual(session.version, editedVersion + 1)
        XCTAssertTrue(session.isDirty)

        session.replaceText("Original")

        XCTAssertFalse(session.isDirty)
    }

    func testRelocateUpdatesMarkdownAndMDXFileKindsAndVersionsWithoutChangingText() {
        let markdownURL = URL(fileURLWithPath: "/tmp/post.md")
        let mdxURL = URL(fileURLWithPath: "/tmp/post.mdx")
        let session = DocumentSession(text: "# Title", url: markdownURL, fileKind: .markdown)
        let originalVersion = session.version

        session.relocate(to: mdxURL)

        XCTAssertEqual(session.fileURL, mdxURL)
        XCTAssertEqual(session.text, "# Title")
        XCTAssertEqual(session.fileKind, .mdx)
        XCTAssertEqual(session.version, originalVersion + 1)
        XCTAssertFalse(session.isDirty)

        session.relocate(to: markdownURL)

        XCTAssertEqual(session.fileURL, markdownURL)
        XCTAssertEqual(session.text, "# Title")
        XCTAssertEqual(session.fileKind, .markdown)
        XCTAssertEqual(session.version, originalVersion + 2)
        XCTAssertFalse(session.isDirty)
    }
}
