import AppKit
import SwiftUI

/// Owned AppKit query field for in-document find (not SwiftUI `FocusState`).
///
/// Focus apply is **key-window only** and **request-token ordered**: the async focus
/// closure re-reads the latest request IDs and does not consume a token until the field
/// actually becomes first responder. Older closures cannot steal focus after a newer
/// ⌘F / ⇧⌘F / Escape intent.
struct EditorFindQueryField: NSViewRepresentable {
    @Binding var text: String
    var focusRequestID: UInt64
    var selectAllRequestID: UInt64
    /// Highest abandoned request; async focus must no-op for `requestID <=` this value.
    var focusSupersededID: UInt64
    /// When false, focus requests are ignored (bar closed / unmounted).
    var isBarVisible: Bool
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
        context.coordinator.lastAppliedFocusRequestID = 0
        context.coordinator.lastAppliedSelectAllRequestID = 0
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.field = field
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onEscape = onEscape
        context.coordinator.isBarVisible = isBarVisible
        context.coordinator.latestFocusRequestID = focusRequestID
        context.coordinator.latestSelectAllRequestID = selectAllRequestID
        context.coordinator.focusSupersededID = focusSupersededID

        // Never overwrite the field while IME marked text is active (Zhuyin/Pinyin).
        let isComposing: Bool = {
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() {
                return true
            }
            return context.coordinator.isComposing
        }()
        if !isComposing, field.stringValue != text {
            field.stringValue = text
        }
        field.isEditable = isEnabled
        field.setAccessibilityIdentifier(EditorFindAccessibility.queryField)

        let needsFocus = isBarVisible
            && focusRequestID != 0
            && focusRequestID > focusSupersededID
            && focusRequestID != context.coordinator.lastAppliedFocusRequestID
        if needsFocus {
            let requestID = focusRequestID
            let selectID = selectAllRequestID
            DispatchQueue.main.async {
                context.coordinator.applyFocusIfEligible(
                    field: field,
                    requestID: requestID,
                    selectAllRequestID: selectID
                )
            }
        } else if isBarVisible,
                  selectAllRequestID != context.coordinator.lastAppliedSelectAllRequestID,
                  focusRequestID == context.coordinator.lastAppliedFocusRequestID,
                  focusRequestID > focusSupersededID
        {
            // Select-all only while already focused on this request.
            if field.window?.isKeyWindow == true,
               field.window?.firstResponder === field.currentEditor()
               || field.window?.firstResponder === field
            {
                context.coordinator.lastAppliedSelectAllRequestID = selectAllRequestID
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        var onEscape: () -> Void
        weak var field: NSTextField?
        var lastAppliedFocusRequestID: UInt64 = 0
        var lastAppliedSelectAllRequestID: UInt64 = 0
        var latestFocusRequestID: UInt64 = 0
        var latestSelectAllRequestID: UInt64 = 0
        var focusSupersededID: UInt64 = 0
        var isBarVisible = false
        var isComposing = false

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onEscape: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onEscape = onEscape
        }

        func applyFocusIfEligible(
            field: NSTextField,
            requestID: UInt64,
            selectAllRequestID: UInt64
        ) {
            // Superseded by a newer focus intent (⌘F again) or abandoned (⇧⌘F / Escape).
            guard requestID == latestFocusRequestID else { return }
            guard requestID > focusSupersededID else { return }
            guard isBarVisible else { return }
            guard let window = field.window, window.isKeyWindow else { return }
            guard requestID != lastAppliedFocusRequestID else { return }

            guard window.makeFirstResponder(field) else { return }
            // Confirm we actually hold focus before consuming the token.
            let focused = window.firstResponder === field
                || window.firstResponder === field.currentEditor()
            guard focused else { return }

            lastAppliedFocusRequestID = requestID
            if selectAllRequestID == latestSelectAllRequestID,
               selectAllRequestID != lastAppliedSelectAllRequestID
            {
                lastAppliedSelectAllRequestID = selectAllRequestID
                field.currentEditor()?.selectAll(nil)
            }
        }

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

        func control(
            _: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
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
