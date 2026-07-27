import AppKit
import STTextView

/// App-facing probe for the focused editor's selection (UTF-16 ranges).
///
/// App must not import STTextView; this keeps the concrete editor type behind EditorKit.
@MainActor
public enum EditorSelectionProbe {
    /// Selected UTF-16 range when the key window's first responder is the Plainsong editor
    /// (or its field editor). Returns `nil` when focus is elsewhere (find field, sidebar, preview).
    public static func keyWindowEditorSelection() -> NSRange? {
        guard let window = NSApp.keyWindow,
              let first = window.firstResponder
        else {
            return nil
        }

        if let textView = first as? STTextView,
           textView.accessibilityIdentifier() == EditorAccessibility.textViewIdentifier
        {
            return textView.selectedRange()
        }

        if let textView = first as? NSTextView {
            if let document = textView.enclosingScrollView?.documentView as? STTextView,
               document.accessibilityIdentifier() == EditorAccessibility.textViewIdentifier
            {
                return document.selectedRange()
            }
            if textView.accessibilityIdentifier() == EditorAccessibility.textViewIdentifier,
               let st = textView as? STTextView
            {
                return st.selectedRange()
            }
        }

        return nil
    }

    /// Selected UTF-16 range of the key window's Plainsong editor **regardless of which view
    /// is first responder**.
    ///
    /// `keyWindowEditorSelection()` answers "is the editor focused, and what is selected".
    /// This answers "what has the editor actually applied", which is what ⌘E needs while the
    /// find field owns focus: a navigation that was published but rejected or superseded
    /// before the editor installed it must not be reported as the selection.
    public static func keyWindowAppliedEditorSelection() -> NSRange? {
        guard let window = NSApp.keyWindow,
              let root = window.contentView,
              let editor = editorTextView(in: root) as? STTextView
        else {
            return nil
        }
        return editor.selectedRange()
    }

    /// Whether the key window's first responder is the Plainsong editor text view.
    public static func keyWindowHasEditorFocus() -> Bool {
        keyWindowEditorSelection() != nil
            || keyWindowEditorTextView() != nil
    }

    public static func keyWindowEditorTextView() -> NSView? {
        guard let window = NSApp.keyWindow,
              let first = window.firstResponder
        else {
            return nil
        }

        if let textView = first as? STTextView,
           textView.accessibilityIdentifier() == EditorAccessibility.textViewIdentifier
        {
            return textView
        }

        if let textView = first as? NSTextView {
            if let document = textView.enclosingScrollView?.documentView as? STTextView,
               document.accessibilityIdentifier() == EditorAccessibility.textViewIdentifier
            {
                return document
            }
            var view: NSView? = textView.superview
            while let current = view {
                if current.accessibilityIdentifier() == EditorAccessibility.textViewIdentifier {
                    return current
                }
                view = current.superview
            }
        }

        if let view = first as? NSView,
           view.accessibilityIdentifier() == EditorAccessibility.textViewIdentifier
        {
            return view
        }

        return nil
    }

    private static func editorTextView(in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == EditorAccessibility.textViewIdentifier {
            return view
        }
        for subview in view.subviews {
            if let match = editorTextView(in: subview) {
                return match
            }
        }
        return nil
    }
}
