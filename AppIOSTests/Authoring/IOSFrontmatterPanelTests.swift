import Foundation
import MarkdownCore
@testable import PlainsongIOS
import XCTest

final class IOSFrontmatterPanelTests: XCTestCase {
    @MainActor
    func testQuotedLiteralStringRoundTrip() throws {
        let source = AuthoringFixtures.frontmatter(body: "BODY")
        let value = "say \"hello\""
        let updated = try XCTUnwrap(Frontmatter.updating(source, key: "title", value: .string(value)))
        let harness = AuthoringHarness(text: source)
        harness.controller.commitFrontmatter(key: "title", value: .string(value), using: harness.editor)
        XCTAssertTrue(ExactSourceText.matches(harness.editor.text, updated))
        XCTAssertTrue(harness.editor.text.contains("custom: keep"))
        let edit = try XCTUnwrap(harness.editor.submitted.last)
        let bodyLocation = (source as NSString).range(of: "BODY").location
        XCTAssertLessThanOrEqual(NSMaxRange(edit.result.replacementRange), bodyLocation)
        XCTAssertEqual(harness.editor.applyCount, 1)
        XCTAssertEqual(edit.undoActionName, "Frontmatter")
    }

    @MainActor
    func testUnicodeAndEmbeddedNewline() throws {
        let source = AuthoringFixtures.frontmatter(body: "BODY")
        let value = "測試\n第二行"
        let updated = try XCTUnwrap(Frontmatter.updating(source, key: "title", value: .string(value)))
        let harness = AuthoringHarness(text: source)
        harness.controller.commitFrontmatter(key: "title", value: .string(value), using: harness.editor)
        XCTAssertTrue(ExactSourceText.matches(harness.editor.text, updated))
        let edit = try XCTUnwrap(harness.editor.submitted.last)
        let bodyLocation = (source as NSString).range(of: "BODY").location
        XCTAssertLessThanOrEqual(NSMaxRange(edit.result.replacementRange), bodyLocation)
    }

    @MainActor
    func testTagsDateAndBool() throws {
        let source = AuthoringFixtures.frontmatter()
        let harness = AuthoringHarness(text: source)
        var expected = try XCTUnwrap(Frontmatter.updating(source, key: "tags", value: .stringList(["a", "b"])))
        harness.controller.commitFrontmatter(key: "tags", value: .stringList(["a", "b"]), using: harness.editor)
        expected = try XCTUnwrap(Frontmatter.updating(expected, key: "date", value: .date("2026-10-08")))
        harness.controller.commitFrontmatter(key: "date", value: .date("2026-10-08"), using: harness.editor)
        harness.controller.toggleFrontmatterBool(key: "draft", using: harness.editor)
        expected = try XCTUnwrap(Frontmatter.updating(expected, key: "draft", value: .bool(true)))
        XCTAssertEqual(harness.editor.applyCount, 3)
        XCTAssertTrue(ExactSourceText.matches(harness.editor.text, expected))
        XCTAssertEqual(harness.editor.submitted.map(\.undoActionName), ["Frontmatter", "Frontmatter", "Frontmatter"])
    }

    @MainActor
    func testUnknownKeysAndCRLF() throws {
        let source = AuthoringFixtures.frontmatter(body: "BODY\r\nNEXT", lineEnding: "\r\n")
        let updated = try XCTUnwrap(Frontmatter.updating(source, key: "title", value: .string("next")))
        XCTAssertTrue(updated.contains("custom: keep"))
        XCTAssertTrue(updated.contains("\r\n"))
        let harness = AuthoringHarness(text: source)
        harness.controller.commitFrontmatter(key: "title", value: .string("next"), using: harness.editor)
        XCTAssertTrue(ExactSourceText.matches(harness.editor.text, updated))
        let edit = try XCTUnwrap(harness.editor.submitted.last)
        let bodyLocation = (source as NSString).range(of: "BODY\r\nNEXT").location
        XCTAssertLessThanOrEqual(NSMaxRange(edit.result.replacementRange), bodyLocation)
    }

    @MainActor
    func testMalformedYAMLShowsRawAndDoesNotRewrite() {
        let source = "---\n- item\n---\nbody\n"
        let harness = AuthoringHarness(text: source)
        harness.controller.noteFrontmatterSource(using: harness.editor)
        let parse = harness.controller.frontmatter.acceptedParse
        XCTAssertNotNil(parse.error)
        XCTAssertFalse(parse.block?.rawYAML.isEmpty ?? true)
        XCTAssertFalse(parse.error?.message.isEmpty ?? true)
        _ = IOSAuthoringFrontmatterPanel(controller: harness.controller, editor: harness.editor).body
        XCTAssertEqual(harness.editor.applyCount, 0)
        XCTAssertEqual(harness.editor.text, source)
    }

    @MainActor
    func testMissingClosingFenceDoesNotRepair() {
        let source = "---\ntitle: \"hello\"\nbody\n"
        let harness = AuthoringHarness(text: source)
        harness.controller.noteFrontmatterSource(using: harness.editor)
        let parse = harness.controller.frontmatter.acceptedParse
        XCTAssertEqual(parse.error?.message, "Missing closing frontmatter delimiter.")
        XCTAssertFalse(parse.block?.rawYAML.isEmpty ?? true)
        _ = IOSAuthoringFrontmatterPanel(controller: harness.controller, editor: harness.editor).body
        XCTAssertEqual(harness.editor.applyCount, 0)
        XCTAssertEqual(harness.editor.text, source)
    }

    @MainActor
    func testAbsentBlockInsertsDefault() {
        let source = "hello\n"
        let harness = AuthoringHarness(text: source)
        let updated = Frontmatter.insertingDefaultBlock(into: source, date: "2026-10-08")
        harness.controller.insertDefaultFrontmatter(date: "2026-10-08", using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 1)
        XCTAssertTrue(ExactSourceText.matches(harness.editor.text, updated))
        XCTAssertEqual(harness.editor.undoCount, 1)
    }

    @MainActor
    func testRawFieldHasNoCommit() throws {
        let source = "---\ntitle: \"hello\"\nextra:\n  nested: 1\n---\nbody\n"
        let harness = AuthoringHarness(text: source)
        harness.controller.noteFrontmatterSource(using: harness.editor)
        let extra = try XCTUnwrap(harness.controller.frontmatter.acceptedParse.block?.fieldValues["extra"])
        guard case .raw = extra else {
            XCTFail("expected a raw field, got \(extra)")
            return
        }
        harness.controller.commitFrontmatter(key: "extra", value: .raw("nope"), using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 0)
        XCTAssertEqual(harness.editor.undoCount, 0)
        XCTAssertEqual(harness.editor.text, source)
        XCTAssertEqual(harness.controller.statusMessage, IOSAuthoringCatalog.frontmatterRefusal)
    }

    @MainActor
    func testDraftRaceKeepsDraftAndNewerSource() throws {
        let source = AuthoringFixtures.frontmatter()
        let harness = AuthoringHarness(text: source)
        harness.controller.beginFrontmatterDraft(using: harness.editor)
        let captured = try XCTUnwrap(harness.controller.frontmatter.capture)
        harness.editor.text = "# other"
        harness.editor.version += 1
        harness.controller.commitFrontmatter(key: "title", value: .string("新標題"), using: harness.editor)
        let edit = try XCTUnwrap(harness.editor.submitted.last)
        XCTAssertEqual(harness.editor.applyCount, 1)
        XCTAssertEqual(edit.baseRevision, captured.revision)
        XCTAssertEqual(edit.bindingID, captured.bindingID)
        XCTAssertEqual(edit.selectionGeneration, captured.selectionGeneration)
        XCTAssertEqual(edit.accessGeneration, captured.accessGeneration)
        XCTAssertEqual(harness.editor.text, "# other")
        XCTAssertEqual(harness.controller.frontmatter.drafts["title"], .string("新標題"))
        XCTAssertEqual(harness.editor.undoCount, 0)
        XCTAssertEqual(harness.editor.outcomes.last, .refused(.sourceChanged))
    }

    @MainActor
    func testSecondConfirmUsesNewSnapshot() throws {
        let source = AuthoringFixtures.frontmatter()
        let harness = AuthoringHarness(text: source, version: 1)
        harness.controller.beginFrontmatterDraft(using: harness.editor)
        let first = try XCTUnwrap(harness.controller.frontmatter.capture).revision
        harness.editor.beforeApply = { harness.editor.version = 2 }
        harness.controller.commitFrontmatter(key: "title", value: .string("changed"), using: harness.editor)
        XCTAssertEqual(harness.editor.submitted.first?.baseRevision, first)
        XCTAssertEqual(harness.editor.outcomes.last, .refused(.sourceChanged))
        harness.controller.commitFrontmatter(key: "title", value: .string("changed"), using: harness.editor)
        let second = try XCTUnwrap(harness.editor.submitted.last)
        XCTAssertEqual(second.baseRevision.version, 2)
        XCTAssertNotEqual(second.baseRevision, first)
        XCTAssertEqual(harness.editor.applyCount, 2)
        XCTAssertEqual(harness.editor.undoCount, 1)
    }

    @MainActor
    func testIdenticalFormDoesNotApply() throws {
        let seed = AuthoringFixtures.frontmatter()
        let stable = try XCTUnwrap(Frontmatter.updating(seed, key: "title", value: .string("hello")))
        let again = try XCTUnwrap(Frontmatter.updating(stable, key: "title", value: .string("hello")))
        XCTAssertTrue(ExactSourceText.matches(stable, again))
        let harness = AuthoringHarness(text: stable, version: 3)
        harness.controller.beginFrontmatterDraft(using: harness.editor)
        harness.controller.commitFrontmatter(key: "title", value: .string("hello"), using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 0)
        XCTAssertEqual(harness.editor.undoCount, 0)
        XCTAssertEqual(harness.editor.version, 3)
        XCTAssertTrue(ExactSourceText.matches(harness.editor.text, stable))
    }

    @MainActor
    func testSelectionBeforeInsideAndAfterDiff() throws {
        let old = "abcd"
        let new = "abXYZcd"
        let edit = try XCTUnwrap(IOSAuthoringSourceDiff.edit(
            from: old,
            to: new,
            selection: NSRange(location: 0, length: 1)
        ))
        XCTAssertEqual(edit.replacementRange, NSRange(location: 2, length: 0))
        XCTAssertEqual(edit.replacementString, "XYZ")
        XCTAssertEqual(edit.newSelection, NSRange(location: 0, length: 1))
        let after = try XCTUnwrap(IOSAuthoringSourceDiff.edit(
            from: old,
            to: new,
            selection: NSRange(location: 4, length: 0)
        ))
        XCTAssertEqual(after.newSelection, NSRange(location: 7, length: 0))
        let caret = try XCTUnwrap(IOSAuthoringSourceDiff.edit(
            from: old,
            to: new,
            selection: NSRange(location: 2, length: 0)
        ))
        XCTAssertEqual(caret.newSelection, NSRange(location: 5, length: 0))
    }

    @MainActor
    func testDiffDoesNotSplitSurrogate() throws {
        let edit = try XCTUnwrap(IOSAuthoringSourceDiff.edit(
            from: "a😀b",
            to: "a😁b",
            selection: NSRange(location: 0, length: 0)
        ))
        XCTAssertEqual(edit.replacementRange, NSRange(location: 1, length: 2))
        XCTAssertNotEqual(edit.replacementRange, NSRange(location: 2, length: 1))
    }

    @MainActor
    func testDiffDoesNotSplitCombiningMark() throws {
        let edit = try XCTUnwrap(IOSAuthoringSourceDiff.edit(
            from: "a\u{0301}",
            to: "a",
            selection: NSRange(location: 0, length: 0)
        ))
        XCTAssertEqual(edit.replacementRange, NSRange(location: 0, length: 2))
        XCTAssertEqual(edit.replacementString, "a")
        XCTAssertNotEqual(edit.replacementRange, NSRange(location: 1, length: 1))
    }

    @MainActor
    func testOverflowingSelectionRefuses() {
        let mapped = IOSAuthoringSourceDiff.mapSelection(
            NSRange(location: Int.max - 1, length: 2),
            replacement: NSRange(location: 0, length: 0),
            newMiddleLength: 5,
            newLength: 10
        )
        XCTAssertNil(mapped)
        let source = AuthoringFixtures.frontmatter()
        let harness = AuthoringHarness(text: source, selection: NSRange(location: 80, length: 5))
        harness.controller.commitFrontmatter(key: "title", value: .string("changed"), using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 0)
        XCTAssertEqual(harness.editor.undoCount, 0)
        XCTAssertEqual(harness.editor.text, source)
    }

    @MainActor
    func testViewDoesNotPaintSourceBeforeApply() {
        let source = AuthoringFixtures.frontmatter()
        let harness = AuthoringHarness(text: source)
        harness.controller.beginFrontmatterDraft(using: harness.editor)
        let accepted = harness.controller.frontmatter.acceptedText
        let updated = Frontmatter.updating(source, key: "title", value: .string("新標題"))
        XCTAssertNotEqual(updated, accepted)
        harness.editor.nextRefusal = .busy
        harness.controller.commitFrontmatter(key: "title", value: .string("新標題"), using: harness.editor)
        XCTAssertEqual(harness.controller.frontmatter.acceptedText, accepted)
        XCTAssertEqual(harness.controller.frontmatter.drafts["title"], .string("新標題"))
        XCTAssertEqual(harness.editor.text, source)
        XCTAssertEqual(harness.editor.applyCount, 1)
        XCTAssertEqual(harness.editor.undoCount, 0)
        XCTAssertEqual(harness.editor.outcomes.last, .refused(.busy))
    }
}
