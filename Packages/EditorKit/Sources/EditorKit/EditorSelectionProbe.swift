import AppKit
import STTextView

/// A selection the editor has actually applied, with the source it belongs to.
///
/// Offsets are only meaningful against the exact document revision they were read from.
/// Callers must reject a selection whose `documentIdentity` / `sourceRevision` does not match
/// the text they are about to index — otherwise a document switch or same-URL Reload can hand
/// out a range from the previous content.
public struct EditorAppliedSelection: Equatable, Sendable {
    public let documentIdentity: EditorDocumentIdentity?
    /// App-owned revision of the source installed in the editor (`DocumentSession.version`).
    public let sourceRevision: Int?
    /// False while a prepared document transition has not finished installing.
    public let isDocumentInstalled: Bool
    public let range: NSRange

    public init(
        documentIdentity: EditorDocumentIdentity?,
        sourceRevision: Int?,
        isDocumentInstalled: Bool,
        range: NSRange
    ) {
        self.documentIdentity = documentIdentity
        self.sourceRevision = sourceRevision
        self.isDocumentInstalled = isDocumentInstalled
        self.range = range
    }
}

/// App-facing probe for the focused editor's selection (UTF-16 ranges).
///
/// App must not import STTextView; this keeps the concrete editor type behind EditorKit.
@MainActor
public enum EditorSelectionProbe {
    /// Selected UTF-16 range when the key window's first responder is the Plainsong editor
    /// (or its field editor). Returns `nil` when focus is elsewhere (find field, sidebar, preview).
    public static func keyWindowEditorSelection() -> NSRange? {
        guard let window = currentKeyWindow else { return nil }
        return editorSelection(in: window)
    }

    /// Window-scoped seam; see `appliedEditorSelection(in:)`.
    static func editorSelection(in window: NSWindow) -> NSRange? {
        guard let first = window.firstResponder else {
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
    /// is first responder**, together with the provenance of the source it belongs to.
    ///
    /// `keyWindowEditorSelection()` answers "is the editor focused, and what is selected".
    /// This answers "what has the editor actually applied, and to which document revision" —
    /// what ⌘E needs while the find field owns focus. A range alone is not safe to consume:
    /// during a document switch or a same-URL Reload the native view can still hold the
    /// previous source, so a caller must check the identity and revision it came from before
    /// interpreting the offsets against its own current text.
    public static func keyWindowAppliedEditorSelection() -> EditorAppliedSelection? {
        guard let window = currentKeyWindow else { return nil }
        return appliedEditorSelection(in: window)
    }

    /// Window-scoped seam. Test runners do not reliably report a programmatic window as
    /// `NSApp.keyWindow`, so the rule is exercised here instead of behind a skip.
    static func appliedEditorSelection(in window: NSWindow) -> EditorAppliedSelection? {
        guard let root = window.contentView,
              let editor = editorTextView(in: root) as? STTextView
        else {
            return nil
        }
        let coordinator = editor.textDelegate as? MarkdownTextViewCoordinator
        return EditorAppliedSelection(
            documentIdentity: coordinator?.currentDocumentIdentity,
            sourceRevision: coordinator?.currentInstalledSourceSnapshot?.revision,
            isDocumentInstalled: coordinator?.isPreparedDocumentInstalled ?? false,
            range: editor.selectedRange()
        )
    }

    /// Test seam: stands in for `NSApp.keyWindow` in every `keyWindow…` entry point.
    ///
    /// A test process cannot make a programmatic window key (`NSApp.keyWindow` stays nil when
    /// the host app is not active), so without this there is no way to tell a window-scoped
    /// implementation from one that consults the global key window — both answer identically.
    /// Production leaves this `nil`. Mirrors `AppState.workspaceSearchFocusKeyWindowCheck`.
    public static var keyWindowOverrideForTesting: (() -> NSWindow?)?

    private static var currentKeyWindow: NSWindow? {
        keyWindowOverrideForTesting?() ?? NSApp.keyWindow
    }

    /// Whether the key window's first responder is the Plainsong editor text view.
    public static func keyWindowHasEditorFocus() -> Bool {
        guard let window = currentKeyWindow else { return false }
        return hasEditorFocus(in: window)
    }

    /// Whether **this** window's first responder is the Plainsong editor text view.
    ///
    /// Window-scoped on purpose: `keyWindowHasEditorFocus()` answers about `NSApp.keyWindow`,
    /// which is the wrong question — and a wrong answer — for a caller asking about a
    /// specific window while a different one holds editor focus.
    public static func hasEditorFocus(in window: NSWindow) -> Bool {
        editorSelection(in: window) != nil
            || editorTextView(focusedIn: window) != nil
    }

    public static func keyWindowEditorTextView() -> NSView? {
        guard let window = currentKeyWindow else { return nil }
        return editorTextView(focusedIn: window)
    }

    /// Window-scoped counterpart of `keyWindowEditorTextView()`.
    public static func editorTextView(focusedIn window: NSWindow) -> NSView? {
        guard let first = window.firstResponder else {
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
