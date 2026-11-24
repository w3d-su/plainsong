import Foundation
@testable import MarkdownCore
import XCTest

/// The block the inspector's Add button inserts must be valid YAML, or the inspector
/// replaces its fields with an Invalid YAML error.
final class FrontmatterDefaultBlockTests: XCTestCase {
    func testDefaultBlockHasAnEmptyQuotedTitle() {
        XCTAssertEqual(
            Frontmatter.insertingDefaultBlock(into: "# Body\n", date: "2026-11-21"),
            "---\ntitle: \"\"\ndate: 2026-11-21\ntags: []\ndraft: false\n---\n# Body\n"
        )
    }

    func testDefaultBlockKeepsCRLFLineEndings() {
        XCTAssertEqual(
            Frontmatter.insertingDefaultBlock(into: "# Body\r\n", date: "2026-11-21"),
            "---\r\ntitle: \"\"\r\ndate: 2026-11-21\r\ntags: []\r\ndraft: false\r\n---\r\n# Body\r\n"
        )
    }
}
