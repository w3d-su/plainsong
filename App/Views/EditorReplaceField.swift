import AppKit
import SwiftUI

/// Owned AppKit single-line replacement field (`docs/editor-replace-gates.md` §5.1, §5.5).
///
/// An `NSTextField` rather than a SwiftUI `TextField`, for the same reason as the query field:
/// App must be able to read this field editor's live marked text at command boundaries (it is
/// the third marked-text owner), and Return / Escape must reach `doCommandBy` so the input
/// context keeps them during composition. It has **no focus token**: Tab or a click reaches
/// it, so it never competes with the query field's receipt.
///
/// The value is literal and single-line. Pasted line breaks are kept and rejected by App's
/// validation with an explicit field error instead of being converted silently.
struct EditorReplaceField: NSViewRepresentable {
    @Binding var text: String
    /// Return without marked text.
    var onSubmit: () -> Void
    /// Escape without marked text.
    var onEscape: () -> Void
    var onOwnerMount: (NSTextField) -> Void
    var onOwnerUnmount: (NSTextField) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onEscape: onEscape)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.focusRingType = .default
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = EditorFindAccessibility.replacementFieldPlaceholder
        field.setAccessibilityLabel(EditorFindAccessibility.replacementFieldLabel)
        field.setAccessibilityIdentifier(EditorFindAccessibility.replacementField)
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        context.coordinator.field = field
        context.coordinator.onOwnerUnmount = onOwnerUnmount
        onOwnerMount(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.field = field
        coordinator.onSubmit = onSubmit
        coordinator.onEscape = onEscape
        // Never overwrite the field while IME marked text is active (Zhuyin/Pinyin).
        let isComposing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
            || coordinator.isComposing
        if !isComposing, field.stringValue != text {
            field.stringValue = text
        }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.onOwnerUnmount(field)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        var onEscape: () -> Void
        var onOwnerUnmount: (NSTextField) -> Void = { _ in }
        weak var field: NSTextField?
        var isComposing = false

        init(text: Binding<String>, onSubmit: @escaping () -> Void, onEscape: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
            self.onEscape = onEscape
        }

        /// A composing value is not a replacement value: it is published only once committed,
        /// so marked text alone never changes the replacement generation.
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() {
                isComposing = true
                return
            }
            isComposing = false
            if text.wrappedValue != field.stringValue {
                text.wrappedValue = field.stringValue
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            isComposing = false
            if text.wrappedValue != field.stringValue {
                text.wrappedValue = field.stringValue
            }
        }

        /// Return and Escape belong to the input context while marked text exists; afterwards
        /// a fresh Return is a fresh explicit Replace. Nothing is queued across composition.
        func control(
            _: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            let isNewline = commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            let isEscape = commandSelector == #selector(NSResponder.cancelOperation(_:))
            if textView.hasMarkedText(), isNewline || isEscape {
                return false
            }
            if isNewline {
                onSubmit()
                return true
            }
            if isEscape {
                onEscape()
                return true
            }
            return false
        }
    }
}
