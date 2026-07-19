import AppKit
import SwiftUI

/// AppKit-backed Search query field.
///
/// Owns the concrete `NSTextField` so focus identity never depends on sibling hierarchy scans.
/// The field is stamped with `WorkspaceSearchFieldFocus.accessibilityIdentifier` at creation and
/// registered on the window's `WindowKeyStateTracker`.
struct WorkspaceSearchQueryField: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var windowKeyState: WindowKeyStateTracker
    var isEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
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
        weak var field: NSTextField?

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if text.wrappedValue != field.stringValue {
                text.wrappedValue = field.stringValue
            }
        }
    }
}
