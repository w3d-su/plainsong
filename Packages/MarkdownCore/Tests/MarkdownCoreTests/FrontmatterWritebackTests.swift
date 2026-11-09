@testable import MarkdownCore
import XCTest

/// Inspector writeback must leave valid YAML that reads back as the edited value, and the
/// inspector must see the same frontmatter fences as the preview and the editor.
final class FrontmatterWritebackTests: XCTestCase {
    func testQuotedKeyEditReplacesTheEntryInsteadOfAddingADuplicate() throws {
        for keyToken in ["\"title\"", "'title'"] {
            let text = "---\n\(keyToken): Old\ndraft: true\n---\nBody\n"
            XCTAssertEqual(try XCTUnwrap(Frontmatter.parse(text).block).fields.map(\.key), ["title", "draft"])

            let updated = try XCTUnwrap(Frontmatter.updating(text, key: "title", value: .string("New")))

            XCTAssertEqual(updated, "---\n\(keyToken): \"New\"\ndraft: true\n---\nBody\n")
            let reparsed = Frontmatter.parse(updated)
            XCTAssertNil(reparsed.error)
            XCTAssertEqual(reparsed.block?.fieldValues["title"], .string("New"))
        }
    }

    func testQuotedKeyMayContainAColon() throws {
        let text = "---\n\"a: b\": one\n---\n"
        let block = try XCTUnwrap(Frontmatter.parse(text).block)
        XCTAssertEqual(block.fields.map(\.key), ["a: b"])
        XCTAssertEqual(block.fields.first?.rawValue, "one")

        let updated = try XCTUnwrap(Frontmatter.updating(text, key: "a: b", value: .string("two")))
        XCTAssertEqual(updated, "---\n\"a: b\": \"two\"\n---\n")
    }

    func testPlainKeyEndsAtTheColonFollowedBySpace() throws {
        let text = "---\nurl: https://example.com/a:b\na:b: c\n---\n"
        let block = try XCTUnwrap(Frontmatter.parse(text).block)
        XCTAssertEqual(block.fields.map(\.key), ["url", "a:b"])
        XCTAssertEqual(block.fieldValues["url"], .string("https://example.com/a:b"))
        XCTAssertEqual(block.fields.last?.rawValue, "c")
    }

    func testAppendedKeyIsQuotedWhenItIsNotAPlainIdentifier() {
        let text = "---\ntitle: Post\n---\n"
        XCTAssertEqual(
            Frontmatter.updating(text, key: "og:image", value: .string("a.png")),
            "---\ntitle: Post\n\"og:image\": \"a.png\"\n---\n"
        )
        XCTAssertEqual(
            Frontmatter.updating(text, key: "slug", value: .string("post")),
            "---\ntitle: Post\nslug: \"post\"\n---\n"
        )
    }

    func testDateTextThatIsNotAPlainScalarIsWrittenQuoted() throws {
        let text = "---\ntitle: Post\ndate: June 16\n---\nBody\n"
        for typed in [
            "{draft: true}",
            "[2026]",
            "a: b",
            "# note",
            "x # note",
            "*alias",
            "&anchor x",
            "!!int 3",
            " padded",
            "two\nlines",
        ] {
            let updated = try XCTUnwrap(
                Frontmatter.updating(text, key: "date", value: .date(typed)),
                typed.debugDescription
            )
            let mapping = try Frontmatter.loadMapping(from: XCTUnwrap(Frontmatter.parse(updated).block).rawYAML)
            XCTAssertEqual(mapping["date"] as? String, typed, typed.debugDescription)
            XCTAssertEqual(Set(mapping.keys), ["title", "date"], typed.debugDescription)
        }
    }

    func testPlainDatesStayPlainAndQuotedDatesStayQuoted() {
        let plain = "---\ndate: 2026-01-01\n---\n"
        XCTAssertEqual(
            Frontmatter.updating(plain, key: "date", value: .date("2026-06-17")),
            "---\ndate: 2026-06-17\n---\n"
        )
        XCTAssertEqual(
            Frontmatter.updating(plain, key: "date", value: .date("June 17, 2026")),
            "---\ndate: June 17, 2026\n---\n"
        )

        let quoted = "---\ndate: \"2026-01-01\"\n---\n"
        XCTAssertEqual(
            Frontmatter.updating(quoted, key: "date", value: .date("2026-06-17")),
            "---\ndate: \"2026-06-17\"\n---\n"
        )
    }

    func testEditThatWouldNotReadBackIsRefused() {
        // An explicit `? key` entry is not a line the rewrite recognizes, so it would append
        // a second `title`. The re-parse sees the duplicate and the edit is refused.
        let explicitKey = "---\n? title\n: Old\n---\nBody\n"
        XCTAssertNil(Frontmatter.parse(explicitKey).error)
        XCTAssertNil(Frontmatter.updating(explicitKey, key: "title", value: .string("New")))
    }

    func testTOMLFrontmatterIsRecognizedAndReadOnly() throws {
        let text = "+++\ntitle = \"Post\"\n+++\nBody\n"
        let result = Frontmatter.parse(text)
        let block = try XCTUnwrap(result.block)

        XCTAssertTrue(result.hasFrontmatter)
        XCTAssertEqual(block.format, .toml)
        XCTAssertEqual(block.rawYAML, "title = \"Post\"\n")
        XCTAssertTrue(block.fields.isEmpty)
        XCTAssertNotNil(result.error)
        XCTAssertNil(Frontmatter.updating(text, key: "title", value: .string("New")))
        XCTAssertEqual(Frontmatter.parse("+++\r\ntitle = 1\r\n+++ \r\n").block?.format, .toml)
    }

    func testUnclosedOrLongerPlusRunIsNotFrontmatter() {
        XCTAssertFalse(Frontmatter.parse("+++\ntitle = \"Post\"\n").hasFrontmatter)
        XCTAssertFalse(Frontmatter.parse("++++\ntitle = 1\n++++\n").hasFrontmatter)
        XCTAssertFalse(Frontmatter.parse("+++x\ntitle = 1\n+++\n").hasFrontmatter)
    }

    func testFenceLinesMayEndWithSpacesOrTabs() {
        let text = "--- \ntitle: Old\n---\t\nBody\n"
        let result = Frontmatter.parse(text)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.block?.fieldValues["title"], .string("Old"))
        XCTAssertEqual(
            Frontmatter.updating(text, key: "title", value: .string("New")),
            "---\ntitle: \"New\"\n---\nBody\n"
        )
        XCTAssertFalse(Frontmatter.parse("----\ntitle: Old\n----\n").hasFrontmatter)
        XCTAssertFalse(Frontmatter.parse("--- x\ntitle: Old\n---\n").hasFrontmatter)
        XCTAssertEqual(
            Frontmatter.parse("---\ntitle: Old\n--- x\n").error?.message,
            "Missing closing frontmatter delimiter."
        )
    }
}
