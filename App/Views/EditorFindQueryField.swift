import AppKit
import SwiftUI

/// Owned AppKit query field for in-document find (not SwiftUI `FocusState`).
struct EditorFindQueryField: NSViewRepresentable {
    @Binding var text: String
    var focusRequestID: UInt64
    var selectAllRequestID: UInt64
    var isEnabled: Bool
    var onSubmit: () -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onEscape: onEscape
        )
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.focusRingType = .default
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = EditorFindAccessibility.queryFieldPlaceholder
        field.setAccessibilityLabel(EditorFindAccessibility.queryFieldLabel)
        field.setAccessibilityIdentifier(EditorFindAccessibility.queryField)
        field.delegate = context.coordinator
        field.isEditable = isEnabled
        field.isSelectable = true
        context.coordinator.field = field
        context.coordinator.lastFocusRequestID = 0
        context.coordinator.lastSelectAllRequestID = 0
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.field = field
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onEscape = onEscape

        if field.stringValue != text {
            field.stringValue = text
        }
        field.isEditable = isEnabled
        field.setAccessibilityIdentifier(EditorFindAccessibility.queryField)

        if focusRequestID != context.coordinator.lastFocusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                if selectAllRequestID != context.coordinator.lastSelectAllRequestID {
                    context.coordinator.lastSelectAllRequestID = selectAllRequestID
                    field.currentEditor()?.selectAll(nil)
                }
            }
        } else if selectAllRequestID != context.coordinator.lastSelectAllRequestID {
            context.coordinator.lastSelectAllRequestID = selectAllRequestID
            if field.window?.firstResponder === field.currentEditor()
                || field.window?.firstResponder === field
            {
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        var onEscape: () -> Void
        weak var field: NSTextField?
        var lastFocusRequestID: UInt64 = 0
        var lastSelectAllRequestID: UInt64 = 0

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onEscape: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onEscape = onEscape
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            // While marked text exists, keep committing ownership with the input context.
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() {
                return
            }
            if text.wrappedValue != field.stringValue {
                text.wrappedValue = field.stringValue
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if text.wrappedValue != field.stringValue {
                text.wrappedValue = field.stringValue
            }
        }

        func control(
            _: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            // IME: while marked text is active, space/Return/escape stay with the input context
            // (same discipline as MarkdownSTTextView's reservation for composition).
            if textView.hasMarkedText() {
                if commandSelector == #selector(NSResponder.insertNewline(_:))
                    || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
                    || commandSelector == #selector(NSResponder.cancelOperation(_:))
                {
                    return false
                }
            }

            if commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            {
                onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onEscape()
                return true
            }
            return false
        }
    }
}
