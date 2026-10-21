import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import XCTest

final class IOSAuthoringGuardedEditTests: XCTestCase {
    @MainActor
    func testFormatFrontmatterAndReplaceShareOneApplyRoute() throws {
        let bold = AuthoringHarness(text: "hello", selection: NSRange(location: 5, length: 0))
        let boldSnapshot = try XCTUnwrap(bold.editor.captureSnapshot())
        bold.controller.perform(.bold, using: bold.editor)
        let boldEdit = try XCTUnwrap(bold.editor.submitted.last)
        XCTAssertEqual(bold.editor.applyCount, 1)
        XCTAssertEqual(bold.editor.undoCount, 1)
        XCTAssertEqual(boldEdit.undoActionName, "Bold")
        XCTAssertEqual(boldEdit.bindingID, boldSnapshot.bindingID)
        XCTAssertEqual(boldEdit.baseRevision, boldSnapshot.revision)
        XCTAssertEqual(boldEdit.selectionGeneration, boldSnapshot.selectionGeneration)
        XCTAssertEqual(boldEdit.accessGeneration, boldSnapshot.accessGeneration)

        let matter = AuthoringHarness(text: AuthoringFixtures.frontmatter())
        matter.controller.toggleFrontmatterBool(key: "draft", using: matter.editor)
        let matterEdit = try XCTUnwrap(matter.editor.submitted.last)
        XCTAssertEqual(matter.editor.applyCount, 1)
        XCTAssertEqual(matter.editor.undoCount, 1)
        XCTAssertEqual(matterEdit.undoActionName, "Frontmatter")
        XCTAssertEqual(matterEdit.bindingID, matter.editor.bindingID)

        let replace = AuthoringHarness(text: "one two", selection: NSRange(location: 0, length: 3))
        replace.controller.setFindQuery("one", using: replace.editor)
        replace.scheduler.finishLatest()
        replace.controller.setReplacement("two")
        replace.controller.perform(.singleReplace, using: replace.editor)
        let replaceEdit = try XCTUnwrap(replace.editor.submitted.last)
        XCTAssertEqual(replace.editor.applyCount, 1)
        XCTAssertEqual(replace.editor.undoCount, 1)
        XCTAssertEqual(replaceEdit.undoActionName, "Replace")
        XCTAssertEqual(replace.editor.text, "two two")
    }

    @MainActor
    func testStaleRevisionRefusesWithZeroMutation() throws {
        let harness = AuthoringHarness(text: "hello", selection: NSRange(location: 0, length: 5), version: 3)
        let original = harness.editor.text
        harness.editor.beforeApply = { harness.editor.version = 4 }
        harness.controller.perform(.bold, using: harness.editor)
        let edit = try XCTUnwrap(harness.editor.submitted.last)
        XCTAssertEqual(edit.baseRevision.version, 3)
        XCTAssertEqual(harness.editor.outcomes.last, .refused(.sourceChanged))
        XCTAssertEqual(harness.editor.text, original)
        XCTAssertEqual(harness.editor.undoCount, 0)
        XCTAssertEqual(harness.editor.applyCount, 1)
    }

    @MainActor
    func testSameVersionDifferentDocumentRefuses() throws {
        let harness = AuthoringHarness(text: "docs", selection: NSRange(location: 0, length: 4), version: 1)
        let documentA = harness.editor.identity
        harness.controller.perform(.link, using: harness.editor)
        harness.controller.setLinkURL("https://example.test")
        harness.editor.identity = IOSDocumentIdentity(rawValue: UUID())
        harness.editor.text = "kept"
        harness.editor.version = 1
        harness.controller.confirmLink(using: harness.editor)
        let edit = try XCTUnwrap(harness.editor.submitted.last)
        XCTAssertEqual(edit.baseRevision.documentID, documentA)
        XCTAssertEqual(edit.baseRevision.version, 1)
        XCTAssertEqual(harness.editor.outcomes.last, .refused(.documentChanged))
        XCTAssertEqual(harness.editor.text, "kept")
        XCTAssertEqual(harness.editor.undoCount, 0)
    }

    @MainActor
    func testSelectionABARefuses() throws {
        let selection = NSRange(location: 0, length: 5)
        let harness = AuthoringHarness(
            text: "hello",
            selection: selection,
            selectionGeneration: 5
        )
        harness.editor.beforeApply = { harness.editor.selectionGeneration = 7 }
        harness.controller.perform(.bold, using: harness.editor)
        let edit = try XCTUnwrap(harness.editor.submitted.last)
        XCTAssertEqual(edit.selectionGeneration, 5)
        XCTAssertEqual(harness.editor.outcomes.last, .refused(.selectionChanged))
        XCTAssertEqual(harness.editor.selectionGeneration, 7)
        XCTAssertEqual(harness.editor.selection, selection)
        XCTAssertEqual(harness.editor.text, "hello")
        XCTAssertEqual(harness.editor.undoCount, 0)
    }

    @MainActor
    func testAccessGenerationABARefuses() throws {
        let harness = AuthoringHarness(text: "hello", selection: NSRange(location: 0, length: 5), accessGeneration: 2)
        let selection = harness.editor.selection
        harness.editor.beforeApply = { harness.editor.accessGeneration = 4 }
        harness.controller.perform(.bold, using: harness.editor)
        let edit = try XCTUnwrap(harness.editor.submitted.last)
        XCTAssertEqual(edit.accessGeneration, 2)
        XCTAssertEqual(harness.editor.outcomes.last, .refused(.accessChanged))
        XCTAssertEqual(harness.editor.accessGeneration, 4)
        XCTAssertEqual(harness.editor.text, "hello")
        XCTAssertEqual(harness.editor.version, 1)
        XCTAssertEqual(harness.editor.selection, selection)
        XCTAssertEqual(harness.editor.undoCount, 0)
    }

    @MainActor
    func testMarkedTextRefusesRevealAndApply() {
        let math = AuthoringHarness(text: "$x$", selection: NSRange(location: 2, length: 0))
        math.editor.hasMarkedText = true
        math.controller.perform(.inlineMath, using: math.editor)
        XCTAssertEqual(math.editor.applyCount, 0)
        XCTAssertEqual(math.editor.revealCalls.count, 0)
        XCTAssertEqual(math.editor.undoCount, 0)

        let replace = AuthoringHarness(text: "one two", selection: NSRange(location: 4, length: 3))
        replace.controller.setFindQuery("one", using: replace.editor)
        replace.scheduler.finishLatest()
        replace.editor.hasMarkedText = true
        replace.controller.setReplacement("ONE")
        replace.controller.perform(.singleReplace, using: replace.editor)
        XCTAssertEqual(replace.editor.applyCount, 0)
        XCTAssertEqual(replace.editor.revealCalls.count, 0)

        let bold = AuthoringHarness(text: "hello", selection: NSRange(location: 0, length: 5))
        bold.editor.hasMarkedText = true
        bold.controller.perform(.bold, using: bold.editor)
        XCTAssertEqual(bold.editor.applyCount, 0)
        XCTAssertEqual(bold.editor.revealCalls.count, 0)
        XCTAssertEqual(bold.editor.undoCount, 0)
    }

    @MainActor
    func testReadOnlyRefuses() throws {
        let harness = AuthoringHarness(text: "hello", selection: NSRange(location: 0, length: 5))
        harness.editor.canWrite = false
        let snapshot = try XCTUnwrap(harness.editor.captureSnapshot())
        harness.controller.perform(.bold, using: harness.editor)
        let edit = try XCTUnwrap(harness.editor.submitted.last)
        XCTAssertEqual(harness.editor.applyCount, 1)
        XCTAssertEqual(harness.editor.outcomes.last, .refused(.readOnly))
        XCTAssertEqual(edit.baseRevision, snapshot.revision)
        XCTAssertEqual(edit.selectionGeneration, snapshot.selectionGeneration)
        XCTAssertEqual(edit.accessGeneration, snapshot.accessGeneration)
        XCTAssertEqual(edit.bindingID, snapshot.bindingID)
        XCTAssertEqual(harness.editor.text, "hello")
        XCTAssertEqual(harness.editor.undoCount, 0)
    }

    @MainActor
    func testBusyRefusalDoesNotRetry() {
        let harness = AuthoringHarness(text: "docs", selection: NSRange(location: 0, length: 4))
        harness.controller.perform(.link, using: harness.editor)
        harness.controller.setLinkURL("https://example.test")
        harness.editor.nextRefusal = .busy
        harness.controller.confirmLink(using: harness.editor)
        XCTAssertEqual(harness.editor.applyCount, 1)
        XCTAssertEqual(harness.editor.outcomes.last, .refused(.busy))
        XCTAssertEqual(harness.controller.linkDraft?.url, "https://example.test")
        XCTAssertEqual(harness.editor.text, "docs")
        XCTAssertEqual(harness.editor.undoCount, 0)
        XCTAssertEqual(harness.editor.applyCount, 1)
    }

    @MainActor
    func testRejectedLinkDraftIsNotRetargeted() {
        let harness = AuthoringHarness(text: "docs", selection: NSRange(location: 0, length: 4))
        harness.controller.perform(.link, using: harness.editor)
        harness.controller.setLinkURL("https://example.test")
        harness.editor.nextRefusal = .busy
        harness.controller.confirmLink(using: harness.editor)
        XCTAssertEqual(harness.controller.linkDraft?.url, "https://example.test")
        XCTAssertEqual(harness.editor.applyCount, 1)
        harness.editor.identity = IOSDocumentIdentity(rawValue: UUID())
        harness.editor.text = "other document"
        XCTAssertEqual(harness.editor.applyCount, 1)
        XCTAssertEqual(harness.controller.linkDraft?.url, "https://example.test")
        XCTAssertEqual(harness.editor.text, "other document")
        XCTAssertEqual(harness.editor.undoCount, 0)
    }
}
