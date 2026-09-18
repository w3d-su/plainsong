@testable import MarkdownCore
import XCTest

final class FrontmatterStringRoundTripTests: XCTestCase {
    func testStringValuesAndListItemsPreserveExactContentsAndTypes() throws {
        let values = [
            "*hello", "@hello", "&hello", "!hello", "%hello", "`hello", "- hello",
            "yes", "NO", "on", "off", "true", "null", "~", "123", "1.2", ".inf",
            "2026-09-06", "\"quoted\"", "'quoted'", "a: b # c", "[one]", "{one: two}",
            "", "  padded  ", "line one\nline two\n", "a\r\nb\rc", "a\tb", "a\\b",
            "a\u{0}b\u{7}\u{1B}", "a\u{85}b\u{2028}c\u{2029}", "中文 🧪 e\u{301}",
            String(repeating: "long word ", count: 100),
        ]
        for ending in ["\n", "\r\n"] {
            let source = ["---", "title: Old", "tags: []", "# retained", "custom: {nested: yes}", "---", "Body", ""]
                .joined(separator: ending)
            for value in values {
                let updated = try XCTUnwrap(Frontmatter.updating(source, key: "title", value: .string(value)))
                let parsed = Frontmatter.parse(updated)
                XCTAssertNil(parsed.error, "Input: \(value.debugDescription)")
                guard case let .string(actual)? = parsed.block?.fieldValues["title"] else {
                    XCTFail("Lost string type for \(value.debugDescription)")
                    continue
                }
                XCTAssertEqual(Array(actual.utf8), Array(value.utf8))
                XCTAssertTrue(updated
                    .hasSuffix("# retained\(ending)custom: {nested: yes}\(ending)---\(ending)Body\(ending)"))
            }
            let updated = try XCTUnwrap(Frontmatter.updating(source, key: "tags", value: .stringList(values)))
            let parsed = Frontmatter.parse(updated)
            XCTAssertNil(parsed.error)
            guard case let .stringList(actual)? = parsed.block?.fieldValues["tags"] else {
                return XCTFail("Lost string list")
            }
            XCTAssertEqual(actual.map { Array($0.utf8) }, values.map { Array($0.utf8) })
        }
    }
}
