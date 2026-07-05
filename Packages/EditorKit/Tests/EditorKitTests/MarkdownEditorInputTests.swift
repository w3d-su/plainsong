import AppKit
@testable import EditorKit
import STTextView
import SwiftUI
import XCTest

final class MarkdownEditorInputTests: XCTestCase {
    @MainActor
    func testSelectionChangeSynchronizesPendingTextBeforeDidChangeNotification() {
        var modelText = ""
        var modelSelection: NSRange?
        let coordinator = MarkdownTextViewCoordinator(
            text: Binding(
                get: { modelText },
                set: { modelText = $0 }
            ),
            selection: Binding(
                get: { modelSelection },
                set: { modelSelection = $0 }
            )
        )
        let textView = MarkdownSTTextView(frame: .zero)
        textView.text = "a"
        textView.textSelection = NSRange(location: 1, length: 0)

        coordinator.textViewDidChangeSelection(Notification(
            name: STTextView.didChangeSelectionNotification,
            object: textView
        ))

        XCTAssertEqual(modelText, "a")
        XCTAssertEqual(modelSelection, NSRange(location: 1, length: 0))
        XCTAssertTrue(coordinator.isUserEditing)
    }

    @MainActor
    func testTextWillChangeMarksUserEditingBeforeTextDidChangeNotification() {
        let coordinator = MarkdownTextViewCoordinator(text: .constant(""), selection: .constant(nil))
        let textView = MarkdownSTTextView(frame: .zero)

        coordinator.textViewWillChangeText(Notification(
            name: STTextView.textWillChangeNotification,
            object: textView
        ))

        XCTAssertTrue(coordinator.isUserEditing)
    }

    @MainActor
    func testReusedCoordinatorWritesEditsToCurrentDocumentBinding() {
        var originalDocumentText = "Original"
        var currentDocumentText = ""
        var originalSelection: NSRange?
        var currentSelection: NSRange?
        let coordinator = MarkdownTextViewCoordinator(
            text: Binding(
                get: { originalDocumentText },
                set: { originalDocumentText = $0 }
            ),
            selection: Binding(
                get: { originalSelection },
                set: { originalSelection = $0 }
            )
        )
        coordinator.updateBindings(
            text: Binding(
                get: { currentDocumentText },
                set: { currentDocumentText = $0 }
            ),
            selection: Binding(
                get: { currentSelection },
                set: { currentSelection = $0 }
            )
        )

        let textView = MarkdownSTTextView(frame: .zero)
        textView.text = "a"
        coordinator.textViewDidChangeText(Notification(
            name: STTextView.textDidChangeNotification,
            object: textView
        ))

        XCTAssertEqual(originalDocumentText, "Original")
        XCTAssertEqual(currentDocumentText, "a")
    }

    @MainActor
    func testMarkedTextCompositionDefersModelSyncUntilCommit() {
        var modelText = ""
        var writes: [String] = []
        let coordinator = MarkdownTextViewCoordinator(
            text: Binding(
                get: { modelText },
                set: {
                    modelText = $0
                    writes.append($0)
                }
            ),
            selection: .constant(nil)
        )
        let textView = MarkdownSTTextView(frame: .zero)
        textView.textDelegate = coordinator
        textView.text = ""
        textView.textSelection = NSRange(location: 0, length: 0)

        textView.setMarkedText(
            "ㄊ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: .notFound
        )

        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertEqual(Self.text(in: textView), "ㄊ")
        XCTAssertTrue(writes.isEmpty)

        textView.insertText("台", replacementRange: .notFound)

        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(Self.text(in: textView), "台")
        XCTAssertEqual(modelText, "台")
        XCTAssertEqual(writes, ["台"])
    }

    @MainActor
    func testFocusRequestRemainsPendingUntilTextViewCanFocus() {
        let coordinator = MarkdownTextViewCoordinator(text: .constant(""), selection: .constant(nil))
        let textView = MarkdownSTTextView(frame: .zero)
        textView.isEditable = true
        textView.isSelectable = true

        coordinator.focusIfNeeded(1, textView: textView)

        XCTAssertNil(coordinator.lastHandledFocusRequestID)
        XCTAssertEqual(coordinator.pendingFocusRequestID, 1)

        // Repeating the same request while the view is still off-window must not
        // mark it handled; SwiftUI can update several times during sheet dismissal.
        coordinator.focusIfNeeded(1, textView: textView)

        XCTAssertNil(coordinator.lastHandledFocusRequestID)
        XCTAssertEqual(coordinator.pendingFocusRequestID, 1)

        coordinator.cancelPendingFocusRequest()
        XCTAssertNil(coordinator.pendingFocusRequestID)
    }

    @MainActor
    private static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }
}
