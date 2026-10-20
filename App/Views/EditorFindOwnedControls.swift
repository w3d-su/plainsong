import AppKit

// AppKit views the find bar owns (Replace PR H). Both report leaving their window while they
// hold focus, so App can hand focus to a surviving owned control instead of stranding it on
// the window — where every Find and Replace command would silently become ineligible.

/// The bar's push and disclosure buttons.
final class EditorFindOwnedButton: NSButton {
    var onRemovalWhileFocused: ((NSWindow) -> Void)?
    /// Escape while this button holds focus. AppKit buttons consume Escape themselves, so the
    /// bar's SwiftUI exit command cannot be relied on to see it.
    var onEscape: (() -> Void)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, window.firstResponder === self {
            onRemovalWhileFocused?(window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func cancelOperation(_ sender: Any?) {
        guard let onEscape else { return super.cancelOperation(sender) }
        onEscape()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let onEscape {
            onEscape()
            return
        }
        super.keyDown(with: event)
    }
}

/// The replacement field. Its field editor, not the field, is first responder while editing,
/// and a teardown removes that editor without `controlTextDidEndEditing` — so the owning
/// delegate tracks editing in `fieldEditorIsActive`, and a still-active editor whose removal
/// just resigned focus to the window counts as focused.
final class EditorFindOwnedTextField: NSTextField {
    var onRemovalWhileFocused: ((NSWindow) -> Void)?
    /// Whether this field's editor is attached. Set by the owning delegate's begin/end
    /// editing callbacks; teardown resigns the editor with no end-editing notification, so
    /// the flag is still true when this view's own removal callbacks run.
    var fieldEditorIsActive = false

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, wasFocusedForRemoval(in: window) {
            onRemovalWhileFocused?(window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Focused means first responder now, or an editor still attached when the teardown
    /// resigned it — that resign reaches the window with no end-editing callback, so the
    /// delegate-maintained `fieldEditorIsActive` is the only record that remains.
    private func wasFocusedForRemoval(in window: NSWindow) -> Bool {
        holdsFocus(in: window)
            || (fieldEditorIsActive && window.firstResponder === window)
    }

    func holdsFocus(in window: NSWindow) -> Bool {
        window.firstResponder === self
            || (window.firstResponder as? NSTextView).map { $0.delegate === self } == true
    }
}
