import AppKit
import Carbon
@testable import Plainsong
import SwiftUI
import XCTest

/// Regression tests for the App/Views review findings (High #34, #36, #37, #38 and the
/// Find/Replace field composition item).
@MainActor
final class AppViewsReviewFixTests: XCTestCase {
    private final class TextBox {
        var value: String
        var writeCount = 0

        init(_ value: String) {
            self.value = value
        }

        var binding: Binding<String> {
            Binding(get: { self.value }, set: {
                self.value = $0
                self.writeCount += 1
            })
        }
    }

    private static let decomposed = "e\u{301}"
    private static let precomposed = "\u{E9}"

    private func makeWindow(hosting field: NSTextField) throws -> (NSWindow, NSTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        return (window, editor)
    }

    private func compose(_ text: String, in editor: NSTextView) {
        editor.setMarkedText(
            text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(editor.hasMarkedText(), "precondition: marked text is active")
    }

    private func textDidChange(_ field: NSTextField) -> Notification {
        Notification(name: NSControl.textDidChangeNotification, object: field)
    }

    // MARK: - #36 workspace Search field

    func testWorkspaceSearchFieldLeavesDownAndEscapeToTheInputContextWhileComposing() {
        var moveDownCount = 0
        var escapeCount = 0
        let coordinator = WorkspaceSearchQueryField.Coordinator(
            text: .constant(""),
            onMoveDownToResults: { moveDownCount += 1 },
            onEscapeToEditor: { escapeCount += 1 },
            onFocusTraversal: nil
        )
        let field = NSTextField(string: "")
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        let moveDown = #selector(NSResponder.moveDown(_:))
        let cancel = #selector(NSResponder.cancelOperation(_:))

        XCTAssertTrue(coordinator.control(field, textView: textView, doCommandBy: moveDown))
        XCTAssertTrue(coordinator.control(field, textView: textView, doCommandBy: cancel))
        XCTAssertEqual([moveDownCount, escapeCount], [1, 1])

        compose("ㄅ", in: textView)
        XCTAssertFalse(
            coordinator.control(field, textView: textView, doCommandBy: moveDown),
            "↓ must pick a candidate, not leave the Search field"
        )
        XCTAssertFalse(
            coordinator.control(field, textView: textView, doCommandBy: cancel),
            "Escape must cancel the composition, not return focus to the editor"
        )
        XCTAssertEqual([moveDownCount, escapeCount], [1, 1])
    }

    func testWorkspaceSearchFieldPublishesOnlyCommittedTextAndKeepsTheComposition() throws {
        let box = TextBox("")
        let coordinator = WorkspaceSearchQueryField.Coordinator(
            text: box.binding,
            onMoveDownToResults: nil,
            onEscapeToEditor: nil,
            onFocusTraversal: nil
        )
        let field = NSTextField(string: "")
        let (window, editor) = try makeWindow(hosting: field)
        defer { window.close() }

        compose("ㄅ", in: editor)
        coordinator.controlTextDidChange(textDidChange(field))
        XCTAssertEqual(box.value, "", "marked text is not a workspace query")
        XCTAssertEqual(box.writeCount, 0)

        // A binding update during composition (a view update) must not drop the marked text.
        coordinator.applyExternalText(box.value, to: field)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "ㄅ")

        editor.insertText("不", replacementRange: editor.markedRange())
        XCTAssertFalse(editor.hasMarkedText())
        coordinator.controlTextDidChange(textDidChange(field))
        XCTAssertEqual(box.value, "不")
    }

    func testWorkspaceSearchFieldComparesExactSourceText() {
        let box = TextBox(Self.precomposed)
        let coordinator = WorkspaceSearchQueryField.Coordinator(
            text: box.binding,
            onMoveDownToResults: nil,
            onEscapeToEditor: nil,
            onFocusTraversal: nil
        )
        let field = NSTextField(string: Self.decomposed)
        coordinator.controlTextDidChange(textDidChange(field))
        XCTAssertEqual(Array(box.value.unicodeScalars), Array(Self.decomposed.unicodeScalars))
    }

    // MARK: - Find / Replace fields

    private func makeFindCoordinator(_ box: TextBox) -> EditorFindQueryField.Coordinator {
        EditorFindQueryField.Coordinator(
            text: box.binding,
            readFocusSnapshot: { EditorFindUIState().focusSnapshot },
            markFocusApplied: { _ in },
            markSelectAllApplied: { _ in },
            onSubmit: {},
            onEscape: {}
        )
    }

    func testFindAndReplaceFieldsPublishCanonicallyEquivalentTextAsANewValue() {
        let findBox = TextBox(Self.precomposed)
        let find = makeFindCoordinator(findBox)
        let findField = NSTextField(string: Self.decomposed)
        find.controlTextDidChange(textDidChange(findField))
        XCTAssertEqual(Array(findBox.value.unicodeScalars), Array(Self.decomposed.unicodeScalars))
        find.applyExternalText(Self.precomposed, to: findField)
        XCTAssertEqual(Array(findField.stringValue.unicodeScalars), Array(Self.precomposed.unicodeScalars))

        let replaceBox = TextBox(Self.precomposed)
        let replace = EditorReplaceField.Coordinator(text: replaceBox.binding, onSubmit: { _ in }, onEscape: {})
        let replaceField = NSTextField(string: Self.decomposed)
        replace.controlTextDidChange(textDidChange(replaceField))
        XCTAssertEqual(Array(replaceBox.value.unicodeScalars), Array(Self.decomposed.unicodeScalars))
        replace.applyExternalText(Self.precomposed, to: replaceField)
        XCTAssertEqual(Array(replaceField.stringValue.unicodeScalars), Array(Self.precomposed.unicodeScalars))
    }

    /// A composition that ends without another text-change notification must not leave the
    /// field refusing binding updates.
    func testFindAndReplaceFieldsAcceptBindingUpdatesOnceCompositionEndsSilently() throws {
        let find = makeFindCoordinator(TextBox(""))
        let replace = EditorReplaceField.Coordinator(text: TextBox("").binding, onSubmit: { _ in }, onEscape: {})
        try assertBindingUpdatesResume(apply: find.applyExternalText, didChange: find.controlTextDidChange)
        try assertBindingUpdatesResume(apply: replace.applyExternalText, didChange: replace.controlTextDidChange)
    }

    private func assertBindingUpdatesResume(
        apply: (String, NSTextField) -> Void,
        didChange: (Notification) -> Void
    ) throws {
        let field = NSTextField(string: "")
        let (window, editor) = try makeWindow(hosting: field)
        defer { window.close() }
        compose("ㄅ", in: editor)
        didChange(textDidChange(field))
        apply("kept out", field)
        XCTAssertEqual(editor.string, "ㄅ", "the composition survives a binding update")

        editor.unmarkText()
        XCTAssertFalse(editor.hasMarkedText())
        apply("next query", field)
        XCTAssertEqual(field.stringValue, "next query")
    }
}
