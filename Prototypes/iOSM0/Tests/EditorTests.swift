@testable import PlainsongIOSM0
import XCTest

final class EditorTests: XCTestCase {
    @MainActor
    func testCleanReloadKeepsIdentityAndAdvancesRevision() {
        let editor = SourceEditor()
        editor.attach("original")
        let identity = editor.documentID
        let revision = editor.revision
        editor.attach("external", identity: identity)
        XCTAssertEqual(editor.documentID, identity)
        XCTAssertGreaterThan(editor.revision, revision)
    }

    @MainActor
    func testTextKit2PresentationPreservesSourceSelectionAndUndoRedo() {
        let editor = SourceEditor()
        XCTAssertTrue(editor.attach("# 中文 👩🏽‍💻\nsecond"))
        XCTAssertNotNil(editor.textView.textLayoutManager)
        editor.textView.selectedRange = NSRange(location: 2, length: 2)
        let before = editor.textView.text
        let selection = editor.textView.selectedRange
        let undo = editor.textView.undoManager?.canUndo
        let redo = editor.textView.undoManager?.canRedo
        XCTAssertTrue(editor.applyPresentation(editor.ticket(), ranges: [NSRange(location: 0, length: 4)]))
        XCTAssertEqual(editor.textView.text, before)
        XCTAssertEqual(editor.textView.selectedRange, selection)
        XCTAssertEqual(editor.textView.undoManager?.canUndo, undo)
        XCTAssertEqual(editor.textView.undoManager?.canRedo, redo)
    }

    @MainActor
    func testStaleRevisionAndDocumentSwitchRefusePresentation() {
        let editor = SourceEditor()
        editor.attach("# old")
        let old = editor.ticket()
        editor.textView.insertText("new")
        editor.textViewDidChange(editor.textView)
        XCTAssertFalse(editor.applyPresentation(old, ranges: [NSRange(location: 0, length: 2)]))
        editor.attach("# other")
        let before = editor.textView.text
        XCTAssertFalse(editor.applyPresentation(old, ranges: [NSRange(location: 0, length: 2)]))
        XCTAssertEqual(editor.textView.text, before)
    }

    @MainActor
    func testMarkedTextRefusesPresentationAttachAndUndo() throws {
        let editor = SourceEditor()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = editor.textView
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        editor.attach("# 中文")
        editor.textView.becomeFirstResponder()
        editor.textView.setMarkedText("ㄓㄨ", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(editor.textView.markedTextRange)
        let source = editor.textView.text
        let selection = editor.textView.selectedRange
        XCTAssertFalse(editor.applyPresentation(editor.ticket(), ranges: [NSRange(location: 0, length: 2)]))
        XCTAssertFalse(editor.attach("replacement"))
        editor.undo()
        XCTAssertEqual(editor.textView.text, source)
        XCTAssertEqual(editor.textView.selectedRange, selection)
        XCTAssertNotNil(editor.textView.markedTextRange)
        editor.textView.unmarkText()
    }

    @MainActor
    func testNativeUndoRoundTripAfterPresentation() throws {
        let editor = SourceEditor()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = editor.textView
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        editor.attach("中文 👩🏽‍💻")
        editor.textView.becomeFirstResponder()
        editor.textView.selectedRange = NSRange(location: editor.textView.text.utf16.count, length: 0)
        let baseline = editor.textView.text
        editor.textView.undoManager?.beginUndoGrouping()
        editor.textView.insertText("\n新增")
        editor.textView.undoManager?.endUndoGrouping()
        editor.textViewDidChange(editor.textView)
        let edited = editor.textView.text
        XCTAssertTrue(editor.applyPresentation(editor.ticket(), ranges: []))
        editor.undo()
        XCTAssertEqual(editor.textView.text, baseline)
        editor.redo()
        XCTAssertEqual(editor.textView.text, edited)
    }
}
