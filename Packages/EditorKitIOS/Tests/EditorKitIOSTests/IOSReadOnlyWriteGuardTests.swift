@testable import EditorKitIOS
import MarkdownCore
import UIKit
import XCTest

/// A binding whose `canWrite` is false (a conflict fence, a revoked grant) must not
/// change through history, native input, or a composition that was already in progress.
@MainActor
final class IOSReadOnlyWriteGuardTests: XCTestCase {
    func testUndoAndRedoAreRefusedWhileReadOnly() {
        let harness = IOSEditorHarness(text: "a")
        harness.placeCaret(at: 1)
        harness.textView.insertText("b")
        XCTAssertEqual(harness.session.text, "ab")
        let version = harness.session.version

        setCanWrite(false, harness, generation: 2)
        harness.controller.undo()
        XCTAssertEqual(harness.textView.textStorage.string, "ab")
        XCTAssertEqual(harness.session.text, "ab")
        XCTAssertEqual(harness.session.version, version)

        setCanWrite(true, harness, generation: 3)
        harness.controller.undo()
        XCTAssertEqual(harness.session.text, "a")
        let undone = harness.session.version

        setCanWrite(false, harness, generation: 4)
        harness.controller.redo()
        XCTAssertEqual(harness.textView.textStorage.string, "a")
        XCTAssertEqual(harness.session.text, "a")
        XCTAssertEqual(harness.session.version, undone)
    }

    /// Shake, the three-finger gesture and a hardware Command-Z reach the text view's own
    /// undo manager without passing through `undo()`.
    func testNativeUndoWhileReadOnlyRestoresTheSessionText() {
        let harness = IOSEditorHarness(text: "a")
        harness.placeCaret(at: 1)
        harness.textView.insertText("b")
        let version = harness.session.version

        setCanWrite(false, harness, generation: 2)
        harness.textView.undoManager?.undo()
        XCTAssertEqual(harness.textView.textStorage.string, "ab")
        XCTAssertEqual(harness.session.text, "ab")
        XCTAssertEqual(harness.session.version, version)
        XCTAssertEqual(harness.textView.undoManager?.canUndo, false)
        XCTAssertEqual(harness.textView.undoManager?.canRedo, false)
    }

    /// Drag and drop or dictation change the buffer without asking the editor first.
    func testUnaskedNativeChangeWhileReadOnlyIsPutBack() {
        let harness = IOSEditorHarness(text: "hello")
        let version = harness.session.version
        setCanWrite(false, harness, generation: 2)

        harness.textView.textStorage.replaceCharacters(in: NSRange(location: 5, length: 0), with: " dropped")
        harness.controller.textViewDidChange(harness.textView)

        XCTAssertEqual(harness.textView.textStorage.string, "hello")
        XCTAssertEqual(harness.session.text, "hello")
        XCTAssertEqual(harness.session.version, version)
    }

    func testCompositionCannotStartWhileReadOnly() {
        let harness = IOSEditorHarness(text: "hello")
        let version = harness.session.version
        setCanWrite(false, harness, generation: 2)

        harness.textView.setMarkedText("ㄓ", selectedRange: NSRange(location: 0, length: 1))
        XCTAssertNil(harness.textView.markedTextRange)
        harness.textView.insertText("x")
        XCTAssertEqual(harness.textView.textStorage.string, "hello")
        XCTAssertEqual(harness.session.text, "hello")
        XCTAssertEqual(harness.session.version, version)
    }

    func testCompositionInProgressCannotCommitNewTextAfterAccessIsRevoked() {
        let harness = IOSEditorHarness(text: "hello")
        harness.placeCaret(at: 5)
        harness.textView.setMarkedText("ㄓ", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(harness.textView.markedTextRange)
        let composing = harness.textView.textStorage.string

        setCanWrite(false, harness, generation: 2)
        let version = harness.session.version
        harness.textView.setMarkedText("ㄓㄨ", selectedRange: NSRange(location: 2, length: 0))
        harness.textView.insertText("中")
        XCTAssertEqual(harness.textView.textStorage.string, composing)
        XCTAssertEqual(harness.session.version, version)
        XCTAssertTrue(ExactSourceText.matches(harness.session.text, harness.textView.textStorage.string))
    }

    func testRefusedCompositionInputEndsTheCompositionSoLaterEditsAreAccepted() {
        let harness = IOSEditorHarness(text: "hello")
        harness.placeCaret(at: 5)
        harness.textView.setMarkedText("ㄓ", selectedRange: NSRange(location: 1, length: 0))
        let composing = harness.textView.textStorage.string

        setCanWrite(false, harness, generation: 2)
        XCTAssertNotNil(harness.textView.markedTextRange, "an idle composition is left for a deferred reload")
        harness.textView.setMarkedText("ㄓㄨ", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNil(harness.textView.markedTextRange)
        XCTAssertEqual(harness.textView.textStorage.string, composing)
        XCTAssertTrue(ExactSourceText.matches(harness.session.text, composing))

        setCanWrite(true, harness, generation: 3)
        harness.placeCaret(at: harness.textView.textStorage.length)
        harness.textView.insertText("x")
        XCTAssertEqual(harness.session.text, composing + "x")
    }

    private func setCanWrite(_ canWrite: Bool, _ harness: IOSEditorHarness, generation: UInt64) {
        harness.controller.updateAccess(
            for: harness.identity,
            bindingID: harness.bindingID,
            generation: generation,
            canWrite: canWrite
        )
    }
}
