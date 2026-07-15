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
        let originalTextBinding = Binding(
            get: { originalDocumentText },
            set: { originalDocumentText = $0 }
        )
        let originalSelectionBinding = Binding(
            get: { originalSelection },
            set: { originalSelection = $0 }
        )
        let coordinator = MarkdownTextViewCoordinator(
            text: originalTextBinding,
            selection: originalSelectionBinding
        )
        let currentTextBinding = Binding(
            get: { currentDocumentText },
            set: { currentDocumentText = $0 }
        )
        let currentSelectionBinding = Binding(
            get: { currentSelection },
            set: { currentSelection = $0 }
        )

        let textView = MarkdownSTTextView(frame: .zero)
        textView.text = originalDocumentText
        installDocument(
            text: originalTextBinding,
            selection: originalSelectionBinding,
            coordinator: coordinator,
            textView: textView
        )

        currentDocumentText = "a"
        textView.text = currentDocumentText
        installDocument(
            text: currentTextBinding,
            selection: currentSelectionBinding,
            coordinator: coordinator,
            textView: textView
        )
        textView.text = "ab"
        coordinator.textViewDidChangeText(Notification(
            name: STTextView.textDidChangeNotification,
            object: textView
        ))

        XCTAssertEqual(originalDocumentText, "Original")
        XCTAssertEqual(currentDocumentText, "ab")
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
    func testMarkedTextCommitReplacesTheSelectionThatBeganComposition() {
        let source = "prefix target suffix"
        let expected = "prefix proposed suffix"
        var modelText = source
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
        textView.text = source
        textView.textSelection = (source as NSString).range(of: "target")

        textView.setMarkedText(
            "draft",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: .notFound
        )
        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertEqual(modelText, source)

        textView.insertText("proposed", replacementRange: .notFound)

        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(Self.text(in: textView), expected)
        XCTAssertEqual(modelText, expected)
        XCTAssertEqual(writes, [expected])
    }

    @MainActor
    func testMarkedTextCommitUsesExplicitReplacementInsteadOfUnrelatedSelection() {
        let source = "prefix target suffix"
        let target = (source as NSString).range(of: "target")
        let expected = "prefix proposed suffix"
        var modelText = source
        let coordinator = MarkdownTextViewCoordinator(
            text: Binding(
                get: { modelText },
                set: { modelText = $0 }
            ),
            selection: .constant(nil)
        )
        let textView = MarkdownSTTextView(frame: .zero)
        textView.textDelegate = coordinator
        textView.text = source
        textView.textSelection = NSRange(location: 0, length: 0)

        textView.setMarkedText(
            "draft",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: target
        )
        textView.insertText("proposed", replacementRange: .notFound)

        XCTAssertEqual(Self.text(in: textView), expected)
        XCTAssertEqual(modelText, expected)
    }

    @MainActor
    func testSelectionOnlyRejectionDoesNotPoisonTheNextMarkedReplacement() {
        let source = "() target"
        let target = (source as NSString).range(of: "target")
        let expected = "() proposed"
        var modelText = source
        let coordinator = MarkdownTextViewCoordinator(
            text: Binding(
                get: { modelText },
                set: { modelText = $0 }
            ),
            selection: .constant(nil)
        )
        let textView = MarkdownSTTextView(frame: .zero)
        textView.textDelegate = coordinator
        textView.text = source
        textView.textSelection = NSRange(location: 1, length: 0)

        textView.insertText(")", replacementRange: .notFound)
        XCTAssertEqual(Self.text(in: textView), source)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))

        textView.textSelection = target
        textView.setMarkedText(
            "draft",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: .notFound
        )
        textView.insertText("proposed", replacementRange: .notFound)

        XCTAssertEqual(Self.text(in: textView), expected)
        XCTAssertEqual(modelText, expected)
    }

    @MainActor
    func testDirectUnmarkClearsReplacementBeforeTheNextComposition() async {
        let source = "first second"
        let first = (source as NSString).range(of: "first")
        let second = (source as NSString).range(of: "second")
        let expected = "first proposed"
        var modelText = source
        let coordinator = MarkdownTextViewCoordinator(
            text: Binding(
                get: { modelText },
                set: { modelText = $0 }
            ),
            selection: .constant(nil)
        )
        let textView = MarkdownSTTextView(frame: .zero)
        textView.textDelegate = coordinator
        textView.text = source
        textView.textSelection = first

        textView.setMarkedText(
            "draft",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: .notFound
        )
        textView.unmarkText()
        await Task.yield()
        XCTAssertEqual(Self.text(in: textView), source)

        textView.textSelection = second
        textView.setMarkedText(
            "draft",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: .notFound
        )
        textView.insertText("proposed", replacementRange: .notFound)

        XCTAssertEqual(Self.text(in: textView), expected)
        XCTAssertEqual(modelText, expected)
    }

    @MainActor
    func testNativeEditPublishesCanonicalEquivalentRawUTF16Sequence() {
        let boundSource = "a\u{301}\u{327}"
        let liveSource = "a\u{327}\u{301}"
        var modelText = boundSource
        var publishedUTF16: [[UInt16]] = []
        let coordinator = MarkdownTextViewCoordinator(
            text: Binding(
                get: { modelText },
                set: {
                    modelText = $0
                    publishedUTF16.append(Array($0.utf16))
                }
            ),
            selection: .constant(nil)
        )
        let textView = MarkdownSTTextView(frame: .zero)
        textView.text = liveSource

        coordinator.textViewDidChangeText(Notification(
            name: STTextView.textDidChangeNotification,
            object: textView
        ))

        XCTAssertEqual(Array(modelText.utf16), Array(liveSource.utf16))
        XCTAssertEqual(Data(modelText.utf8), Data(liveSource.utf8))
        XCTAssertEqual(publishedUTF16, [Array(liveSource.utf16)])
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
    private func installDocument(
        text: Binding<String>,
        selection: Binding<NSRange?>,
        coordinator: MarkdownTextViewCoordinator,
        textView: MarkdownSTTextView
    ) {
        let candidate = coordinator.prepareDocumentTransition(
            text: text,
            selection: selection,
            documentIdentity: nil,
            navigationCommand: nil,
            in: textView
        )
        coordinator.finishDocumentTransition(candidate, in: textView)
    }

    @MainActor
    private static func text(in textView: STTextView) -> String {
        MarkdownTextView.textStorage(of: textView)?.string ?? textView.text ?? ""
    }
}
