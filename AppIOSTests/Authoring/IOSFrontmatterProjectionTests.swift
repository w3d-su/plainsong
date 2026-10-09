import EditorKitIOS
import Foundation
import MarkdownCore
@testable import PlainsongIOS
import XCTest

final class IOSFrontmatterProjectionTests: XCTestCase {
    @MainActor
    func testNoDraftProjectionTracksNativeEditAndUndo() {
        let original = AuthoringFixtures.frontmatter()
        let h = AuthoringHarness(text: original)
        h.controller.noteFrontmatterSource(using: h.editor)
        h.editor.text = AuthoringFixtures.frontmatter(titleLine: "title: changed")
        h.editor.version += 1
        h.controller.noteFrontmatterSource(using: h.editor)
        XCTAssertEqual(h.controller.frontmatter.acceptedParse.block?.fieldValues["title"], .string("changed"))
        h.editor.text = original
        h.editor.version += 1
        h.controller.noteFrontmatterSource(using: h.editor)
        XCTAssertEqual(h.controller.frontmatter.acceptedParse.block?.fieldValues["title"], .string("hello"))
        XCTAssertEqual(h.editor.applyCount, 0)
    }

    @MainActor
    func testFreshProjectionPreservesDraftAndItsOriginalAuthorization() {
        let h = AuthoringHarness(text: AuthoringFixtures.frontmatter())
        h.controller.beginFrontmatterDraft(using: h.editor)
        let captured = h.controller.frontmatter.capture?.revision
        h.controller.setFrontmatterDraft(key: "title", value: .string("my draft"), using: h.editor)
        h.editor.text = AuthoringFixtures.frontmatter(titleLine: "title: external")
        h.editor.version += 1
        h.controller.noteFrontmatterSource(using: h.editor)
        XCTAssertEqual(h.controller.frontmatter.capture?.revision, captured)
        XCTAssertEqual(h.controller.frontmatter.drafts["title"], .string("my draft"))
        XCTAssertEqual(h.controller.frontmatter.acceptedParse.block?.fieldValues["title"], .string("external"))
        h.controller.commitFrontmatter(key: "title", value: .string("my draft"), using: h.editor)
        XCTAssertEqual(h.editor.outcomes.last, .refused(.sourceChanged))
        XCTAssertTrue(h.editor.text.contains("title: external"))
        XCTAssertEqual(h.editor.undoCount, 0)
    }

    @MainActor
    func testDocumentSwitchPreservesOldDraftWithoutApplyingItToNewDocument() {
        let h = AuthoringHarness(text: AuthoringFixtures.frontmatter())
        h.controller.setFrontmatterDraft(key: "title", value: .string("old draft"), using: h.editor)
        h.editor.identity = IOSDocumentIdentity(rawValue: UUID())
        h.editor.bindingID = UUID()
        h.editor.text = AuthoringFixtures.frontmatter(titleLine: "title: new")
        h.controller.noteFrontmatterSource(using: h.editor)
        XCTAssertEqual(h.controller.frontmatter.drafts["title"], .string("old draft"))
        let field = h.controller.frontmatter.acceptedParse.block?.fields.first { $0.key == "title" }
        if let field {
            XCTAssertEqual(h.controller.displayedFrontmatterValue(field), .string("new"))
        } else {
            XCTFail("missing current document title")
        }
        h.controller.commitFrontmatter(key: "title", value: .string("old draft"), using: h.editor)
        h.controller.commitFrontmatter(key: "title", value: .string("old draft"), using: h.editor)
        XCTAssertEqual(h.editor.applyCount, 0)
        XCTAssertTrue(h.editor.text.contains("title: new"))
        h.controller.discardFrontmatterDrafts(using: h.editor)
        XCTAssertTrue(h.controller.frontmatter.drafts.isEmpty)
        XCTAssertEqual(h.controller.frontmatter.capture?.bindingID, h.editor.bindingID)
    }

    @MainActor
    func testAddChecksCurrentSourceInsteadOfPreviouslyAbsentProjection() {
        let h = AuthoringHarness(text: "body")
        h.controller.noteFrontmatterSource(using: h.editor)
        XCTAssertNil(h.controller.frontmatter.acceptedParse.block)
        h.editor.text = AuthoringFixtures.frontmatter()
        h.editor.version += 1
        let before = h.editor.text
        h.controller.insertDefaultFrontmatter(date: "2026-10-09", using: h.editor)
        XCTAssertEqual(h.editor.text, before)
        XCTAssertEqual(h.editor.applyCount, 0)
        XCTAssertEqual(h.editor.undoCount, 0)
        XCTAssertNotNil(h.controller.frontmatter.acceptedParse.block)
    }

    @MainActor
    func testAddDoesNotRewriteMalformedExistingBlock() {
        let h = AuthoringHarness(text: "---\ntitle: missing end\n")
        let before = h.editor.text
        h.controller.insertDefaultFrontmatter(date: "2026-10-09", using: h.editor)
        XCTAssertEqual(h.editor.text, before)
        XCTAssertEqual(h.editor.applyCount, 0)
        XCTAssertNotNil(h.controller.frontmatter.acceptedParse.error)
    }

    @MainActor
    func testBindingObservationPublishesFreshProjectionAndCanBeCancelled() {
        let editor = FrontmatterObservedEditor(text: AuthoringFixtures.frontmatter())
        let controller = IOSAuthoringController()
        controller.startObservingFrontmatter(using: editor)
        editor.changeSource(AuthoringFixtures.frontmatter(titleLine: "title: observed"))
        XCTAssertEqual(controller.frontmatter.acceptedParse.block?.fieldValues["title"], .string("observed"))
        controller.stopObservingFrontmatter()
        editor.changeSource(AuthoringFixtures.frontmatter(titleLine: "title: afterCancel"))
        XCTAssertEqual(controller.frontmatter.acceptedParse.block?.fieldValues["title"], .string("observed"))
    }
}

@MainActor
private final class FrontmatterObservedEditor: IOSSourceEditorBinding {
    let base: AuthoringEditorFake
    var handler: (@MainActor (IOSSourceEditorEvent) -> Void)?

    init(text: String) {
        base = AuthoringEditorFake(text: text)
    }

    func captureSnapshot() -> IOSSourceEditorSnapshot? {
        base.captureSnapshot()
    }

    func apply(_ edit: IOSAuthorizedEdit) -> IOSEditOutcome {
        base.apply(edit)
    }

    func reveal(_ range: NSRange, expected: IOSDocumentRevision) -> Bool {
        base.reveal(range, expected: expected)
    }

    func undo() {
        base.undo()
    }

    func redo() {
        base.redo()
    }

    func attach(_: IOSSourceEditorDocumentBinding) {}
    func detach(expected _: IOSDocumentIdentity, bindingID _: UUID) {}
    func updateAccess(for _: IOSDocumentIdentity, bindingID _: UUID, generation _: UInt64, canWrite _: Bool) {}
    func updateCommandFocus(for _: IOSDocumentIdentity, bindingID _: UUID, isFocused _: Bool) {}
    func installExternalReload(_: IOSDocumentReloadProposal) -> IOSDocumentReloadOutcome {
        .deferred
    }

    func observe(_ handler: @escaping @MainActor (IOSSourceEditorEvent) -> Void) -> any IOSObservation {
        self.handler = handler
        return FrontmatterObservation { [weak self] in self?.handler = nil }
    }

    func changeSource(_ text: String) {
        base.text = text
        base.version += 1
        if let snapshot = captureSnapshot() { handler?(.snapshotChanged(snapshot)) }
    }
}

@MainActor
private final class FrontmatterObservation: IOSObservation {
    private var cancellation: (() -> Void)?
    init(_ cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation?()
        cancellation = nil
    }
}
