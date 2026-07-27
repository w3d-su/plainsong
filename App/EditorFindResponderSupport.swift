import AppKit
import EditorKit
import Foundation

/// First-responder eligibility for the in-document find menu commands (⌘F / ⌘G / ⇧⌘G / ⌘E).
///
/// Kept out of `AppState+EditorFind.swift` so neither file grows past the §17.10 length
/// guidance; the rules themselves are documented on each member.
enum EditorFindResponderSupport {
    @MainActor
    static func keyWindowHasEditorOrFindField() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        return windowHasEditorOrFindChrome(window)
    }

    /// Whether `window`'s first responder is the editor, the find query field, or any other
    /// control inside the find bar.
    ///
    /// Exposed for tests so the rule can be exercised on a synthetic hierarchy without
    /// depending on which window `NSApp` considers key.
    @MainActor
    static func windowHasEditorOrFindChrome(_ window: NSWindow) -> Bool {
        if EditorSelectionProbe.keyWindowHasEditorFocus() {
            return true
        }
        guard let first = window.firstResponder else { return false }
        if matchesEditorOrFindFieldResponder(first) {
            return true
        }
        return responderIsInsideFindBarChrome(first, in: window)
    }

    /// True when the responder sits inside the find bar's own view subtree.
    ///
    /// Anchored on the owned query `NSTextField` rather than on SwiftUI accessibility (which
    /// does not materialize without an assistive client): walk up from the responder to the
    /// nearest ancestor that contains the query field, and accept only if that ancestor does
    /// not also contain the editor. The bar's host view contains the query field and its
    /// sibling controls but never the editor, while any shared ancestor — sidebar, preview,
    /// window content — contains both. This is what keeps ⌘G live after Full Keyboard Access
    /// tabs to Aa / whole-word / Next / Previous.
    @MainActor
    private static func responderIsInsideFindBarChrome(
        _ first: NSResponder,
        in window: NSWindow
    ) -> Bool {
        guard let root = window.contentView,
              let responderView = responderView(for: first),
              let queryField = descendant(of: root, identifiedBy: EditorFindAccessibility.queryField)
        else {
            return false
        }
        let editor = descendant(of: root, identifiedBy: EditorAccessibility.textViewIdentifier)
        var ancestor: NSView? = responderView
        while let current = ancestor {
            if queryField.isDescendant(of: current) {
                if let editor, editor.isDescendant(of: current) {
                    return false
                }
                return true
            }
            ancestor = current.superview
        }
        return false
    }

    @MainActor
    private static func responderView(for first: NSResponder) -> NSView? {
        if let textView = first as? NSTextView {
            // Field editors are not in the chrome hierarchy; their delegate/owner is.
            if let owner = textView.delegate as? NSView {
                return owner
            }
            return textView.superview ?? textView
        }
        return first as? NSView
    }

    @MainActor
    private static func descendant(of view: NSView, identifiedBy identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        for subview in view.subviews {
            if let match = descendant(of: subview, identifiedBy: identifier) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private static func matchesEditorOrFindFieldResponder(_ first: NSResponder) -> Bool {
        if let view = first as? NSView, matchesEditorOrFindField(view) {
            return true
        }
        // Field editor (NSTextView) for the find field or editor.
        if let textView = first as? NSTextView {
            if textView.enclosingScrollView?.documentView?.accessibilityIdentifier()
                == EditorAccessibility.textViewIdentifier
            {
                return true
            }
            if let document = textView.enclosingScrollView?.documentView as? NSView,
               matchesEditorOrFindField(document)
            {
                return true
            }
            var view: NSView? = textView.superview
            while let current = view {
                if matchesEditorOrFindField(current) { return true }
                view = current.superview
            }
            // Field editor owned by the find NSTextField.
            if let field = textView.delegate as? NSTextField,
               field.accessibilityIdentifier() == EditorFindAccessibility.queryField
            {
                return true
            }
        }
        return false
    }

    @MainActor
    private static func matchesEditorOrFindField(_ view: NSView) -> Bool {
        let id = view.accessibilityIdentifier() ?? ""
        if id == EditorAccessibility.textViewIdentifier { return true }
        if id == EditorFindAccessibility.queryField { return true }
        if let field = view as? NSTextField,
           field.accessibilityIdentifier() == EditorFindAccessibility.queryField
        {
            return true
        }
        return false
    }
}
