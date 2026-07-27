import AppKit
import EditorKit
import Foundation

/// Document-lifecycle notifications for in-document find: edits, external replacement,
/// identity rekey, workspace-search hand-off, document switch, and workspace close.
///
/// Every entry point either rebinds the controller to the current document or fences it,
/// so a find generation started under older state can never publish navigation afterwards.
@MainActor
extension AppState {
    func notifyEditorFindDocumentDidChange() {
        guard editorFindHost.ui.isBarVisible || editorFindHost.controller.query != nil else { return }
        ensureEditorFindSessionObserverInstalled()
        cancelPublishedFindNavigationOnSharedChannel()
        let session = currentDocument
        let binding = EditorFindDocumentBinding(
            identity: activeEditorDocumentIdentity,
            text: session.text,
            revision: UInt64(max(0, session.version))
        )
        if editorFindHost.controller.documentBinding.identity != binding.identity {
            editorFindHost.controller.rebindDocument(binding)
        } else {
            editorFindHost.controller.documentTextDidChange(text: binding.text, revision: binding.revision)
        }
        // Counter refresh arrives via onSessionDidChange when the recompute finishes.
    }

    /// Text/revision changed for the same session identity without going through
    /// `applyDocumentText` (External Reload, Keep Mine, clean auto-adoption).
    func notifyEditorFindExternalContentDidReplace() {
        notifyEditorFindDocumentDidChange()
    }

    /// URL / retained identity rekey (rename, move, Save Copy adoption) without a full
    /// document switch — rebind so Find identity tracks the new URL.
    func notifyEditorFindDocumentIdentityDidRekey() {
        guard editorFindHost.ui.isBarVisible || editorFindHost.controller.query != nil else {
            // Still drop any published nav under the old identity.
            cancelPublishedFindNavigationOnSharedChannel()
            editorFindHost.latestKnownEditorSelection = nil
            return
        }
        ensureEditorFindSessionObserverInstalled()
        cancelPublishedFindNavigationOnSharedChannel()
        editorFindHost.latestKnownEditorSelection = nil
        let binding = EditorFindDocumentBinding(
            identity: activeEditorDocumentIdentity,
            text: currentDocument.text,
            revision: UInt64(max(0, currentDocument.version))
        )
        editorFindHost.controller.rebindDocument(binding)
    }

    /// Workspace search is about to take the editor selection for `selection`.
    ///
    /// `commitWorkspaceSearchActivation` skips `setCurrentDocument` when the result is
    /// already the current document, so nothing else fences find there. Without this, a find
    /// match that started computing *before* the activation lands afterwards, draws a higher
    /// navigation ID from the shared generation, and drags the selection back to the find
    /// hit. Must run before the search navigation is issued so its cancel carries the older ID.
    func notifyEditorFindWorkspaceSearchWillNavigate(to selection: NSRange) {
        editorFindHost.latestKnownEditorSelection = nil
        guard editorFindHost.ui.isBarVisible || editorFindHost.controller.query != nil else {
            return
        }
        ensureEditorFindSessionObserverInstalled()
        syncEditorFindControllerDocument()
        yieldEditorFindNavigation(caretAnchorUTF16: selection.location)
    }

    /// Gives up find's claim on the editor selection without losing the query.
    ///
    /// Re-runs the retained query as a counter-only (`.patternOnly`) generation: that cancels
    /// in-flight work, drops any unpublished navigation and pending step intent, publishes a
    /// cancel on the shared channel through `onSessionDidChange`, and still refreshes the
    /// counter. The first later ⌘G activates the match at the new anchor instead of stepping
    /// past it.
    func yieldEditorFindNavigation(caretAnchorUTF16 anchor: Int?) {
        guard let query = editorFindHost.controller.query, !query.pattern.isEmpty else {
            editorFindHost.controller.cancelInFlightWork()
            cancelPublishedFindNavigationOnSharedChannel()
            return
        }
        if let anchor {
            editorFindHost.controller.setCaretAnchor(anchor)
        }
        editorFindHost.controller.setQuery(query, emitsNavigation: false)
    }

    func notifyEditorFindDocumentDidSwitch() {
        // Drop selection cache — ranges are document-scoped.
        editorFindHost.latestKnownEditorSelection = nil
        cancelPublishedFindNavigationOnSharedChannel()

        if !hasOpenDocument {
            editorFindHost.controller.clearForNoDocument()
            var ui = editorFindHost.ui
            ui.closeBar()
            ui.applySessionPresentation(nil)
            setEditorFindUI(ui)
            setEditorFindChromeFocus(nil)
            return
        }
        ensureEditorFindSessionObserverInstalled()
        let binding = EditorFindDocumentBinding(
            identity: activeEditorDocumentIdentity,
            text: currentDocument.text,
            revision: UInt64(max(0, currentDocument.version))
        )
        if editorFindHost.ui.isBarVisible {
            var ui = editorFindHost.ui
            ui.resetChromeKeepingQuery()
            setEditorFindUI(ui)
            // Rebind re-runs the retained controller query with `.rebind` (counter only).
            editorFindHost.controller.rebindDocument(binding)
        } else if editorFindHost.controller.query != nil {
            editorFindHost.controller.rebindDocument(binding)
        }
    }

    func notifyEditorFindWorkspaceDidClose() {
        // clearForNoDocument clears controller query + session so the next open does not
        // re-run a background find against a new document.
        cancelPublishedFindNavigationOnSharedChannel()
        editorFindHost.controller.clearForNoDocument()
        editorFindHost.latestKnownEditorSelection = nil
        var ui = editorFindHost.ui
        ui.closeBar()
        ui.queryText = ""
        ui.applySessionPresentation(nil)
        setEditorFindUI(ui)
        setEditorFindChromeFocus(nil)
    }
}
