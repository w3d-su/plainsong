@testable import MarkdownCore
import XCTest

final class FrontmatterTests: XCTestCase {
    func testParsesTypedFrontmatterValuesInSourceOrder() throws {
        let text = """
        ---
        title: Plainsong
        date: 2026-06-16
        tags:
          - swift
          - mdx
        draft: false
        slug: plainsong
        ---
        # Body
        """

        let result = Frontmatter.parse(text)
        let block = try XCTUnwrap(result.block)

        XCTAssertNil(result.error)
        XCTAssertEqual(block.fields.map(\.key), ["title", "date", "tags", "draft", "slug"])
        XCTAssertEqual(block.fieldValues["title"], .string("Plainsong"))
        XCTAssertEqual(block.fieldValues["date"], .date("2026-06-16"))
        XCTAssertEqual(block.fieldValues["tags"], .stringList(["swift", "mdx"]))
        XCTAssertEqual(block.fieldValues["draft"], .bool(false))
    }

    func testEditingOneKeyPreservesUnknownKeysBodyAndCRLFTerminators() {
        let text = "---\r\ntitle: Old\r\ncustom:\r\n  nested: yes\r\ndraft: false\r\n---\r\n# Body\r\n"

        let updated = Frontmatter.updating(text, key: "title", value: .string("New"))

        XCTAssertEqual(
            updated,
            "---\r\ntitle: New\r\ncustom:\r\n  nested: yes\r\ndraft: false\r\n---\r\n# Body\r\n"
        )
    }

    func testEditingKeyPreservesCommentBetweenKeys() {
        let text = """
        ---
        title: Hello
        # important note about tags
        tags: [a]
        ---
        Body
        """

        let updated = Frontmatter.updating(text, key: "title", value: .string("World"))

        XCTAssertEqual(
            updated,
            """
            ---
            title: World
            # important note about tags
            tags: [a]
            ---
            Body
            """
        )
    }

    func testEditingKeyPreservesTrailingCommentBeforeClosingFence() {
        let text = """
        ---
        title: Hello
        tags: [a]
        # trailing note
        ---
        Body
        """

        let updated = Frontmatter.updating(text, key: "tags", value: .stringList(["b"]))

        XCTAssertEqual(
            updated,
            """
            ---
            title: Hello
            tags:
              - b
            # trailing note
            ---
            Body
            """
        )
    }

    func testEditingKeyPreservesBlankLineBetweenKeys() {
        let text = """
        ---
        title: Hello

        tags: [a]
        ---
        Body
        """

        let updated = Frontmatter.updating(text, key: "title", value: .string("World"))

        XCTAssertEqual(
            updated,
            """
            ---
            title: World

            tags: [a]
            ---
            Body
            """
        )
    }

    func testNestedMappingParsesAsReadOnlyRawSource() throws {
        let text = """
        ---
        title: Post
        author:
          name: Ann
          url: https://example.com
        ---
        Body
        """

        let block = try XCTUnwrap(Frontmatter.parse(text).block)
        let author = try XCTUnwrap(block.fields.first { $0.key == "author" })

        XCTAssertEqual(author.value, .raw("  name: Ann\n  url: https://example.com"))
        XCTAssertEqual(author.rawValue, "  name: Ann\n  url: https://example.com")
        XCTAssertFalse(author.isEditable)
    }

    func testEditingDifferentKeyPreservesNestedMappingByteForByte() {
        let text = "---\r\ntitle: Old\r\nauthor:\r\n  name: Ann\r\n  url: https://example.com\r\ndraft: false\r\n---\r\nBody\r\n"

        let updated = Frontmatter.updating(text, key: "title", value: .string("New"))

        XCTAssertEqual(
            updated,
            "---\r\ntitle: New\r\nauthor:\r\n  name: Ann\r\n  url: https://example.com\r\ndraft: false\r\n---\r\nBody\r\n"
        )
    }

    func testEditingTagsDateAndDraftWritesTypedValues() throws {
        let text = """
        ---
        title: Post
        tags: [old]
        date: 2026-01-01
        draft: true
        ---
        Body
        """

        let tagsUpdated = try XCTUnwrap(Frontmatter.updating(
            text,
            key: "tags",
            value: .stringList(["swift", "frontmatter"])
        ))
        XCTAssertTrue(tagsUpdated.contains("tags:\n  - swift\n  - frontmatter\n"))

        let dateUpdated = try XCTUnwrap(Frontmatter.updating(
            tagsUpdated,
            key: "date",
            value: .date("2026-06-16")
        ))
        XCTAssertTrue(dateUpdated.contains("date: 2026-06-16\n"))

        let draftUpdated = try XCTUnwrap(Frontmatter.updating(
            dateUpdated,
            key: "draft",
            value: .bool(false)
        ))
        XCTAssertTrue(draftUpdated.contains("draft: false\n"))

        let reparsed = try XCTUnwrap(Frontmatter.parse(draftUpdated).block)
        XCTAssertEqual(reparsed.fieldValues["tags"], .stringList(["swift", "frontmatter"]))
        XCTAssertEqual(reparsed.fieldValues["date"], .date("2026-06-16"))
        XCTAssertEqual(reparsed.fieldValues["draft"], .bool(false))
    }

    func testMalformedYAMLKeepsRawTextAndDoesNotRewrite() throws {
        let text = """
        ---
        title: [broken
        ---
        Body
        """

        let result = Frontmatter.parse(text)
        let block = try XCTUnwrap(result.block)

        XCTAssertNotNil(result.error)
        XCTAssertEqual(block.rawYAML, "title: [broken\n")
        XCTAssertNil(Frontmatter.updating(text, key: "title", value: .string("Fixed")))
    }

    func testMissingFrontmatterDoesNotRewrite() {
        let text = "# Plain Markdown\n"

        let result = Frontmatter.parse(text)

        XCTAssertFalse(result.hasFrontmatter)
        XCTAssertNil(Frontmatter.updating(text, key: "title", value: .string("Post")))
    }

    func testPlainCalendarDateClassification() {
        XCTAssertTrue(Frontmatter.isPlainCalendarDate("2026-06-16"))
        XCTAssertFalse(Frontmatter.isPlainCalendarDate("2026-06-16T08:30:00Z"))
        XCTAssertFalse(Frontmatter.isPlainCalendarDate("June 16, 2026"))
        XCTAssertFalse(Frontmatter.isPlainCalendarDate("2026-6-16"))
        XCTAssertFalse(Frontmatter.isPlainCalendarDate("2026-02-30"))
    }

    func testNonPlainDateRoundTripsVerbatimThroughWriteback() throws {
        let text = """
        ---
        title: Post
        date: 2026-06-16T08:30:00Z
        ---
        Body
        """

        let titleUpdated = try XCTUnwrap(Frontmatter.updating(text, key: "title", value: .string("Updated")))
        XCTAssertTrue(titleUpdated.contains("date: 2026-06-16T08:30:00Z\n"))

        let dateUpdated = try XCTUnwrap(Frontmatter.updating(
            titleUpdated,
            key: "date",
            value: .date("2026-06-16T08:30:00Z")
        ))
        XCTAssertTrue(dateUpdated.contains("date: 2026-06-16T08:30:00Z\n"))
    }
}
