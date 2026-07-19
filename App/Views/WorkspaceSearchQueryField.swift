import AppKit
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
struct WorkspaceSearchQueryField: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var windowKeyState: WindowKeyStateTracker
    var isEnabled: Bool
    var onMoveDownToResults: (() -> Void)?
    var onEscapeToEditor: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onMoveDownToResults: onMoveDownToResults,
            onEscapeToEditor: onEscapeToEditor
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

        if field.stringValue != text {
            field.stringValue = text
        }
        field.isEditable = isEnabled
        field.placeholderString = WorkspaceSearchFieldFocus.placeholder
        WorkspaceSearchFieldFocus.stampSearchFieldIdentity(on: field)

        if let window = field.window {
            windowKeyState.attach(to: window)
        }
        windowKeyState.bindSearchField(field)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onMoveDownToResults: (() -> Void)?
        var onEscapeToEditor: (() -> Void)?
        weak var field: NSTextField?

        init(
            text: Binding<String>,
            onMoveDownToResults: (() -> Void)?,
            onEscapeToEditor: (() -> Void)?
        ) {
            self.text = text
            self.onMoveDownToResults = onMoveDownToResults
            self.onEscapeToEditor = onEscapeToEditor
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if text.wrappedValue != field.stringValue {
                text.wrappedValue = field.stringValue
            }
        }

        func control(
            _: NSControl,
            textView _: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
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
            return false
        }
    }
}
