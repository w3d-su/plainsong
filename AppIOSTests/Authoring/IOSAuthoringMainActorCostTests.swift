import MarkdownCore
@testable import PlainsongIOS
import XCTest

final class IOSAuthoringMainActorCostTests: XCTestCase {
    func testLocalGraphemeFloorMatchesEveryCharacterBoundary() {
        let samples = [
            "", "abc", "a\r\nb", "e\u{301}x", "👨‍👩‍👧‍👦!", "🇹🇼🇯🇵", "中文\u{FE0F}", "a👍🏽b\r\n\r\nc",
        ]
        for text in samples {
            var boundaries = [0]
            for character in text {
                boundaries.append((boundaries.last ?? 0) + character.utf16.count)
            }
            for offset in 0 ... text.utf16.count {
                let expected = boundaries.last { $0 <= offset }
                let floor = IOSAuthoringSourceDiff.floor(offset, in: text)
                XCTAssertEqual(floor, expected, "\(text.debugDescription) \(offset)")
            }
            XCTAssertEqual(IOSAuthoringSourceDiff.floor(text.utf16.count + 5, in: text), text.utf16.count)
        }
    }

    func testHeadCoversAClosedBlockThroughItsClosingLine() {
        for ending in ["\n", "\r\n", "\r"] {
            let head = ["---", "title: a", "--- \t"].joined(separator: ending) + ending
            let text = head + "BODY"
            XCTAssertEqual(
                IOSFrontmatterHead.length(of: text, parse: Frontmatter.parse(text)),
                head.utf16.count,
                ending.debugDescription
            )
        }
        for text in ["body", "---\ntitle: a\n", "---\ntitle: a\n---", "---\ntitle: a\n---x\n"] {
            XCTAssertNil(IOSFrontmatterHead.length(of: text, parse: Frontmatter.parse(text)), text.debugDescription)
        }
    }

    @MainActor
    func testBodyEditsKeepTheParseAndBlockEditsReplaceIt() {
        let harness = AuthoringHarness(text: AuthoringFixtures.frontmatter())
        harness.controller.noteFrontmatterSource(using: harness.editor)
        let head = harness.controller.frontmatter.acceptedHeadLength
        XCTAssertNotNil(head)

        let edits = [
            AuthoringFixtures.frontmatter(body: "BODY more"),
            AuthoringFixtures.frontmatter(body: "\n---\ntitle: fake\n---\n"),
            AuthoringFixtures.frontmatter(titleLine: "title: changed"),
            AuthoringFixtures.frontmatter(titleLine: "title: changed", extraLines: []),
            "---\ntitle: open\n",
            "plain",
            AuthoringFixtures.frontmatter(lineEnding: "\r\n"),
        ]
        for text in edits {
            harness.editor.text = text
            harness.editor.version += 1
            harness.controller.noteFrontmatterSource(using: harness.editor)
            XCTAssertEqual(harness.controller.frontmatter.acceptedParse, Frontmatter.parse(text), text.debugDescription)
            XCTAssertEqual(harness.controller.frontmatter.acceptedText, text)
        }
        XCTAssertTrue(IOSFrontmatterHead.isShared(
            head ?? 0, by: AuthoringFixtures.frontmatter(), and: AuthoringFixtures.frontmatter(body: "x")
        ))
        XCTAssertFalse(IOSFrontmatterHead.isShared(
            head ?? 0, by: AuthoringFixtures.frontmatter(), and: AuthoringFixtures.frontmatter(titleLine: "title: b")
        ))
    }
}
