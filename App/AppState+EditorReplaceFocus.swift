import AppKit
import EditorKit
import Foundation

/// Replacement-row focus and transient-state upkeep (Replace PR H): the key window, focus
/// hand-off when a focused row control unmounts, Escape's composition guard, and withdrawing
/// a blocked message once its fence clears.
@MainActor
extension AppState {
    /// `NSApp.keyWindow`, or the test override. An installed override is authoritative even
    /// when it designates no window.
    func editorFindKeyWindow() -> NSWindow? {
        if let override = editorFindHost.keyWindowOverride {
            return override()
        }
        return NSApp.keyWindow
    }

    /// Escape reaching find-bar chrome through the responder chain must not close the bar
    /// while **either** owned field composes. A field editor that declines `cancelOperation:`
    /// lets the event bubble past it, so the guard is re-checked here against live AppKit
    /// state (the marked-text owner registry), never a cached flag.
    func keyWindowFindFieldIsComposing() -> Bool {
        guard let keyWindow = editorFindKeyWindow() else { return false }
        return editorFindHost.replaceMarkedTextOwners.hasMarkedText(in: ObjectIdentifier(keyWindow))
    }

    /// A focused row control is leaving `window`. Without a hand-off, focus falls to the window
    /// itself and ⌘F, ⌘G, ⌘E, Find and Replace… and typing all silently stop working.
    ///
    /// - Cancel unmounting while the row stays (preparation ended, superseded, or committed)
    ///   hands focus to Replace All, or to the replacement field when Replace All is disabled.
    /// - Anything unmounting because the row collapsed goes to the query field.
    /// - A closing bar needs nothing here: closing already returns focus to the editor.
    ///
    /// Focus moves directly, with no focus token or receipt.
    func handOffEditorReplaceFocus(fromRemoved identifier: String, in window: NSWindow) {
        let ui = editorFindHost.ui
        guard ui.isBarVisible, let root = window.contentView else { return }
        var targets: [String] = []
        if ui.isReplaceExpanded, identifier == EditorFindAccessibility.replaceCancelButton {
            // Read App state, not the button: SwiftUI may disable it later in this same update.
            if ui.hasActiveQuery, ui.replacementValidity == .valid {
                targets.append(EditorFindAccessibility.replaceAllButton)
            }
            targets.append(EditorFindAccessibility.replacementField)
        }
        targets.append(EditorFindAccessibility.queryField)
        for target in targets where target != identifier {
            guard let view = EditorFindResponderSupport.ownedView(target, under: root) else {
                continue
            }
            guard window.makeFirstResponder(view) else { continue }
            return
        }
    }

    /// A blocked message names a §5.6 fence; once that fence no longer holds for the current
    /// document (for example the autosave's own disk inspection settled), the message is
    /// withdrawn. Evaluated only while a blocked message is shown, on a later main turn so it
    /// never publishes inside a view update.
    func scheduleStaleEditorReplaceBlockedStatusCheck() {
        guard editorFindHost.replaceStatus?.blockedReason != nil,
              !editorFindHost.isBlockedStatusCheckPending
        else { return }
        editorFindHost.isBlockedStatusCheckPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            editorFindHost.isBlockedStatusCheckPending = false
            guard let reason = editorFindHost.replaceStatus?.blockedReason,
                  editorReplaceAuthorizationDecision(for: currentDocument) != .refused(reason)
            else { return }
            clearEditorReplaceStatus()
        }
    }
}
