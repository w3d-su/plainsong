import AppKit
import EditorKit
import Foundation

/// First-responder eligibility for the in-document find menu commands (⌘F / ⌘G / ⇧⌘G / ⌘E).
///
/// Kept out of `AppState+EditorFind.swift` so neither file grows past the §17.10 length
/// guidance; the rules themselves are documented on each member.
/// Whether a selection the editor has applied may be interpreted against App's current text.
///
/// A native selection is an offset into whatever source the editor currently holds. During a
/// document switch, or a same-URL Reload, that is still the *previous* content while App has
/// already moved on — so a range copied out of it would index new text with old offsets.
/// Identity, installed state, revision, and bounds must all agree.
enum EditorFindAppliedSelectionPolicy {
    static func accepts(
        _ applied: EditorAppliedSelection,
        identity: EditorDocumentIdentity?,
        revision: Int,
        textUTF16Length: Int
    ) -> Bool {
        guard applied.isDocumentInstalled,
              let appliedIdentity = applied.documentIdentity,
              let currentIdentity = identity,
              appliedIdentity == currentIdentity,
              applied.sourceRevision == revision,
              applied.range.location != NSNotFound,
              applied.range.location >= 0,
              applied.range.length >= 0,
              applied.range.length <= Int.max - applied.range.location,
              NSMaxRange(applied.range) <= textUTF16Length
        else {
            return false
        }
        return true
    }
}

enum EditorFindResponderSupport {
    @MainActor
    static func keyWindowHasEditorOrFindField() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        return windowHasEditorOrFindChrome(window)
    }

    /// Whether `window`'s first responder is the editor or the owned find query field.
    ///
    /// This covers only what AppKit can actually answer. The bar's other controls (Aa,
    /// whole-word, Next, Previous, Done) are plain SwiftUI: macOS flattens them and the
    /// editor into a single hosting view, so there is no find-bar-specific ancestor to walk
    /// and no reliable per-control `NSView` to identify. Focus on those is reported by
    /// SwiftUI instead — see `AppState.isEditorFindCommandContextActive()`, which consults
    /// `chromeFocusByWindow` first and falls back to this check whenever that path does not
    /// apply: the bar is hidden, **or** the key window has no entry of its own.
    ///
    /// Exposed for tests so the rule can be exercised without depending on which window
    /// `NSApp` considers key.
    @MainActor
    static func windowHasEditorOrFindChrome(_ window: NSWindow) -> Bool {
        if EditorSelectionProbe.keyWindowHasEditorFocus() {
            return true
        }
        guard let first = window.firstResponder else { return false }
        return matchesEditorOrFindFieldResponder(first)
    }

    /// Whether the key window's owned find query field currently has IME marked text.
    ///
    /// Escape reaching find-bar chrome through the responder chain must not close the bar
    /// mid-composition. A field editor that declines `cancelOperation:` lets the event bubble
    /// past it, so the guard has to be re-checked where the bar handles it, against live
    /// AppKit state rather than a cached flag.
    @MainActor
    static func keyWindowQueryFieldIsComposing() -> Bool {
        guard let root = NSApp.keyWindow?.contentView,
              let field = descendant(
                  of: root,
                  identifiedBy: EditorFindAccessibility.queryField
              ) as? NSTextField,
              let editor = field.currentEditor() as? NSTextView
        else {
            return false
        }
        return editor.hasMarkedText()
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
