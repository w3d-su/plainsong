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
    /// `override` is `EditorFindHost.keyWindowOverride`: when installed it is authoritative,
    /// even when it designates no window, so a test host's real key window cannot leak in.
    @MainActor
    static func keyWindowHasEditorOrFindField(override: (() -> NSWindow?)? = nil) -> Bool {
        let keyWindow: NSWindow? = if let override { override() } else { NSApp.keyWindow }
        guard let window = keyWindow else { return false }
        return windowHasEditorOrFindChrome(window)
    }

    /// Whether `window`'s first responder is the editor or an owned find field (the query or
    /// the replacement field; both count as provenance for that window, §5.1).
    ///
    /// This covers only what AppKit can actually answer. The bar's other controls (Aa,
    /// whole-word, Next, Previous, Done) are plain SwiftUI: macOS flattens them and the
    /// editor into a single hosting view, so there is no find-bar-specific ancestor to walk
    /// and no reliable per-control `NSView` to identify. Focus on those is reported by
    /// SwiftUI instead — see `AppState.isEditorFindCommandContextActive()`, which consults
    /// `chromeFocusByWindow` first and falls back to this check whenever that path does not
    /// apply: the bar is hidden, **or** the key window has no entry of its own.
    ///
    /// Every check is scoped to `window`. It previously asked
    /// `EditorSelectionProbe.keyWindowHasEditorFocus()` first, which answers about
    /// `NSApp.keyWindow` — so asking about window B returned `true` whenever window A held
    /// editor focus. Exposed for tests, which rely on that scoping.
    @MainActor
    static func windowHasEditorOrFindChrome(_ window: NSWindow) -> Bool {
        if EditorSelectionProbe.hasEditorFocus(in: window) {
            return true
        }
        guard let first = window.firstResponder else { return false }
        return matchesEditorOrFindFieldResponder(first)
    }

    /// The owned find-bar view with `identifier` under `root` (fields, row buttons).
    @MainActor
    static func ownedView(_ identifier: String, under root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier {
            return root
        }
        for subview in root.subviews {
            if let match = ownedView(identifier, under: subview) {
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
            // Field editor owned by an owned find NSTextField.
            if let field = textView.delegate as? NSTextField,
               isOwnedFindFieldIdentifier(field.accessibilityIdentifier())
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
        if isOwnedFindFieldIdentifier(id) { return true }
        if let field = view as? NSTextField,
           isOwnedFindFieldIdentifier(field.accessibilityIdentifier())
        {
            return true
        }
        return false
    }

    /// The owned AppKit find chrome: both fields, the disclosure, and the replacement row's
    /// buttons (`EditorFindBarButton`), which Full Keyboard Access focuses as real responders.
    private static func isOwnedFindFieldIdentifier(_ identifier: String?) -> Bool {
        switch identifier {
        case EditorFindAccessibility.queryField, EditorFindAccessibility.replacementField,
             EditorFindAccessibility.replaceDisclosure, EditorFindAccessibility.replaceButton,
             EditorFindAccessibility.replaceAllButton, EditorFindAccessibility.replaceCancelButton:
            true
        default:
            false
        }
    }
}
