import AppKit
import MarkdownCore
import SwiftUI

/// AppKit-backed Search query field.
///
/// Owns the concrete `NSTextField` so focus identity never depends on sibling hierarchy scans.
/// The field is stamped with `WorkspaceSearchFieldFocus.accessibilityIdentifier` at creation and
/// registered on the window's `WindowKeyStateTracker`.
///
/// Keyboard (WS3C PR C):
/// - ↓ → move selection/focus into the results list (`onMoveDownToResults`)
/// - Escape → return focus to the editor without clearing query/results (`onEscapeToEditor`)
///
/// While the field editor has IME marked text (Zhuyin/Pinyin), ↓ and Escape belong to the
/// input context, the composing value is not published as a query, and the field is not
/// overwritten from the binding.
struct WorkspaceSearchQueryField: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var windowKeyState: WindowKeyStateTracker
    var isEnabled: Bool
    var onMoveDownToResults: (() -> Void)?
    var onEscapeToEditor: (() -> Void)?
    var onFocusTraversal: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onMoveDownToResults: onMoveDownToResults,
            onEscapeToEditor: onEscapeToEditor,
            onFocusTraversal: onFocusTraversal
        )
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .default
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = WorkspaceSearchFieldFocus.placeholder
        field.setAccessibilityLabel(WorkspaceSearchFieldFocus.accessibilityLabel)
        WorkspaceSearchFieldFocus.stampSearchFieldIdentity(on: field)
        field.delegate = context.coordinator
        field.isEditable = isEnabled
        field.isSelectable = true
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.field = field
        context.coordinator.onMoveDownToResults = onMoveDownToResults
        context.coordinator.onEscapeToEditor = onEscapeToEditor
        context.coordinator.onFocusTraversal = onFocusTraversal

        context.coordinator.applyExternalText(text, to: field)
        field.isEditable = isEnabled
        field.placeholderString = WorkspaceSearchFieldFocus.placeholder
        WorkspaceSearchFieldFocus.stampSearchFieldIdentity(on: field)

        if let window = field.window {
            windowKeyState.attach(to: window)
        }
        windowKeyState.bindSearchField(field)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onMoveDownToResults: (() -> Void)?
        var onEscapeToEditor: (() -> Void)?
        var onFocusTraversal: (() -> Void)?
        weak var field: NSTextField?

        init(
            text: Binding<String>,
            onMoveDownToResults: (() -> Void)?,
            onEscapeToEditor: (() -> Void)?,
            onFocusTraversal: (() -> Void)?
        ) {
            self.text = text
            self.onMoveDownToResults = onMoveDownToResults
            self.onEscapeToEditor = onEscapeToEditor
            self.onFocusTraversal = onFocusTraversal
        }

        /// Never overwrites the field while its editor has marked text: that would drop the
        /// composition.
        func applyExternalText(_ newText: String, to field: NSTextField) {
            guard !Self.hasMarkedText(field) else { return }
            if !ExactSourceText.matches(field.stringValue, newText) {
                field.stringValue = newText
            }
        }

        /// A composing value is not a query: it is published once committed.
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, !Self.hasMarkedText(field) else { return }
            publish(field.stringValue)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            publish(field.stringValue)
        }

        private func publish(_ value: String) {
            if !ExactSourceText.matches(text.wrappedValue, value) {
                text.wrappedValue = value
            }
        }

        private static func hasMarkedText(_ field: NSTextField) -> Bool {
            (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        }

        func control(
            _: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            // ↓ picks a candidate and Escape cancels the composition; Tab stays with the
            // input context too.
            if textView.hasMarkedText() {
                return false
            }
            // Only swallow when a callback is installed; otherwise let AppKit handle the key.
            if commandSelector == #selector(NSResponder.moveDown(_:)),
               let onMoveDownToResults
            {
                onMoveDownToResults()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)),
               let onEscapeToEditor
            {
                onEscapeToEditor()
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:))
                || commandSelector == #selector(NSResponder.insertBacktab(_:))
            {
                onFocusTraversal?()
                // Preserve AppKit's native next/previous key-view traversal.
                return false
            }
            return false
        }
    }
}
