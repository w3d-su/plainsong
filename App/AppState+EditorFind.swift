import AppKit
import EditorKit
import Foundation
import MarkdownCore

@MainActor
extension AppState {
    /// Publishes find chrome so SwiftUI sees `@Published`-style updates for the host box.
    func setEditorFindUI(_ ui: EditorFindUIState) {
        editorFindHost.ui = ui
        objectWillChange.send()
    }

    /// Wire controller → App presentation/navigation once. Match completion is async and
    /// debounced; a fixed sleep after `setQuery` races and leaves hits unmarked.
    ///
    /// Also installs `navigationIDProvider` so find shares App's workspace-search
    /// high-water mark (F3 shared ID domain contract from PR B).
    func ensureEditorFindSessionObserverInstalled() {
        guard !editorFindHost.didInstallSessionObserver else { return }
        editorFindHost.didInstallSessionObserver = true
        editorFindHost.controller.navigationIDProvider = { [weak self] in
            guard let self else { return 0 }
            return advanceEditorNavigationGeneration()
        }
        editorFindHost.controller.onSessionDidChange = { [weak self] in
            guard let self else { return }
            publishEditorFindSessionPresentation()
            // While a generation is in flight, session is nil — cancel any already-published
            // App navigation so a superseded range cannot still apply.
            if editorFindHost.controller.session == nil,
               editorFindHost.controller.pendingNavigationCommand == nil
            {
                cancelPublishedFindNavigationOnSharedChannel()
            } else {
                applyEditorFindNavigationIfNeeded()
            }
        }
    }

    /// Whether the key window's first responder is the editor, its field editor, or the find field.
    func isEditorFindCommandContextActive() -> Bool {
        guard hasOpenDocument else { return false }
        if let override = editorFindHost.commandContextOverride {
            return override
        }
        return EditorFindResponderSupport.keyWindowHasEditorOrFindField()
    }

    /// ⌘F — show or re-focus; never closes.
    ///
    /// No-op when focus is not the editor or find field (sidebar / preview), even if the
    /// bar is already visible — bar visibility alone does not grant command eligibility.
    func showOrRefocusEditorFind() {
        guard hasOpenDocument else { return }
        guard isEditorFindCommandContextActive() else { return }

        ensureEditorFindSessionObserverInstalled()
        refreshEditorFindCaretFromResponderIfPossible()
        let wasVisible = editorFindHost.ui.isBarVisible
        var ui = editorFindHost.ui
        ui.isBarVisible = true
        ui.requestFocusAndSelectAll()
        setEditorFindUI(ui)
        syncEditorFindControllerDocument()
        if !wasVisible, !editorFindHost.ui.queryText.isEmpty {
            pushEditorFindQueryToController()
        }
    }

    /// Escape / Done — close bar and return focus to editor.
    func closeEditorFindBar() {
        guard editorFindHost.ui.isBarVisible else { return }
        var ui = editorFindHost.ui
        ui.closeBar() // also supersedes pending focus
        setEditorFindUI(ui)
        requestEditorFocus()
    }

    /// Abandon any unapplied Find focus request (⇧⌘F, external focus owners).
    /// Does not change `focusRequestID` — keeps F7 token independence.
    func supersedePendingEditorFindFocus() {
        var ui = editorFindHost.ui
        let before = ui.focusSupersededID
        ui.supersedePendingFocus()
        guard ui.focusSupersededID != before else { return }
        setEditorFindUI(ui)
    }

    func editorFindNext() {
        guard hasOpenDocument else { return }
        guard isEditorFindCommandContextActive() else { return }
        ensureEditorFindSessionObserverInstalled()
        refreshEditorFindCaretFromResponderIfPossible()
        if !editorFindHost.ui.isBarVisible {
            syncEditorFindControllerDocument()
        }
        // While session is nil (debounce), records pending next intent — does not re-push query.
        editorFindHost.controller.findNext()
    }

    func editorFindPrevious() {
        guard hasOpenDocument else { return }
        guard isEditorFindCommandContextActive() else { return }
        ensureEditorFindSessionObserverInstalled()
        refreshEditorFindCaretFromResponderIfPossible()
        if !editorFindHost.ui.isBarVisible {
            syncEditorFindControllerDocument()
        }
        editorFindHost.controller.findPrevious()
    }

    /// ⌘E — macOS convention: set pattern from selection **without** showing/focusing the bar
    /// and **without** auto-navigating (subsequent ⌘G jumps). Format ▸ Inline Code no longer
    /// claims ⌘E (Decision Log).
    func useSelectionForEditorFind() {
        guard hasOpenDocument else { return }
        guard isEditorFindCommandContextActive() else { return }

        ensureEditorFindSessionObserverInstalled()
        refreshEditorFindCaretFromResponderIfPossible()
        let selection = currentEditorSelectionUTF16()
        let text = currentDocument.text as NSString
        guard selection.location != NSNotFound,
              selection.length > 0,
              NSMaxRange(selection) <= text.length
        else {
            return
        }
        let selected = text.substring(with: selection)
        guard !selected.isEmpty,
              selected.utf16.count <= TextSearchEngine.maximumPatternUTF16Length,
              !selected.contains(where: \.isNewline)
        else {
            return
        }

        var ui = editorFindHost.ui
        ui.queryText = selected
        setEditorFindUI(ui)
        editorFindHost.controller.setCaretAnchor(selection.location)
        syncEditorFindControllerDocument()
        cancelPublishedFindNavigationOnSharedChannel()
        // Pattern-only: recompute counter, no auto-jump (⌘G activates).
        editorFindHost.controller.setQuery(
            editorFindHost.ui.makeSearchQuery(),
            emitsNavigation: false
        )
    }

    func handleEditorFindQueryTextChange(_ text: String) {
        ensureEditorFindSessionObserverInstalled()
        var ui = editorFindHost.ui
        ui.queryText = text
        setEditorFindUI(ui)
        syncEditorFindControllerDocument()
        if let known = editorFindHost.latestKnownEditorSelection,
           known.documentIdentity == activeEditorDocumentIdentity
        {
            editorFindHost.controller.setCaretAnchor(known.range.location)
        }
        cancelPublishedFindNavigationOnSharedChannel()
        pushEditorFindQueryToController()
    }

    func handleEditorFindOptionsChange() {
        ensureEditorFindSessionObserverInstalled()
        syncEditorFindControllerDocument()
        cancelPublishedFindNavigationOnSharedChannel()
        pushEditorFindQueryToController()
    }

    func setEditorFindMatchCase(_ matchCase: Bool) {
        guard editorFindHost.ui.matchCase != matchCase else { return }
        var ui = editorFindHost.ui
        ui.matchCase = matchCase
        setEditorFindUI(ui)
        handleEditorFindOptionsChange()
    }

    func setEditorFindWholeWord(_ wholeWord: Bool) {
        guard editorFindHost.ui.wholeWord != wholeWord else { return }
        var ui = editorFindHost.ui
        ui.wholeWord = wholeWord
        setEditorFindUI(ui)
        handleEditorFindOptionsChange()
    }

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
    }

    // MARK: - Internals

    func syncEditorFindControllerDocument() {
        guard hasOpenDocument else {
            editorFindHost.controller.clearForNoDocument()
            return
        }
        let binding = EditorFindDocumentBinding(
            identity: activeEditorDocumentIdentity,
            text: currentDocument.text,
            revision: UInt64(max(0, currentDocument.version))
        )
        if editorFindHost.controller.documentBinding.identity != binding.identity {
            editorFindHost.controller.rebindDocument(binding)
        } else if editorFindHost.controller.documentBinding.revision != binding.revision
            || editorFindHost.controller.documentBinding.text != binding.text
        {
            editorFindHost.controller.documentTextDidChange(
                text: binding.text,
                revision: binding.revision
            )
        } else if editorFindHost.controller.documentBinding.identity == nil {
            editorFindHost.controller.rebindDocument(binding)
        }
    }

    func pushEditorFindQueryToController() {
        ensureEditorFindSessionObserverInstalled()
        let query = editorFindHost.ui.makeSearchQuery()
        if query.pattern.isEmpty {
            editorFindHost.controller.setQuery(nil)
            // onSessionDidChange refreshes chrome; still publish immediately for empty.
            publishEditorFindSessionPresentation()
            return
        }
        editorFindHost.controller.setQuery(query)
        // Counter + selection apply via onSessionDidChange when the debounced match lands.
    }

    private func publishEditorFindSessionPresentation() {
        var ui = editorFindHost.ui
        ui.applySessionPresentation(editorFindHost.controller.session)
        setEditorFindUI(ui)
    }

    /// Publish the controller's pending navigation on the shared App channel.
    /// IDs are already from `navigationIDProvider` → `advanceEditorNavigationGeneration`
    /// (do **not** allocate a second ID here).
    private func applyEditorFindNavigationIfNeeded() {
        guard let command = editorFindHost.controller.pendingNavigationCommand else { return }
        let id = command.id
        if let last = editorFindHost.lastPublishedFindNavigationID, id <= last {
            return
        }
        editorFindHost.lastPublishedFindNavigationID = id
        // Keep selection cache in sync so ⌘E after ⌘G uses the navigated range, not a stale one.
        if case let .navigate(request) = command {
            editorFindHost.latestKnownEditorSelection = EditorFindCachedSelection(
                documentIdentity: request.documentIdentity,
                range: request.selection
            )
        }
        // Reassign so SwiftUI/EditorKit observes a new command value.
        editorNavigationCommand = nil
        editorNavigationCommand = command
    }

    /// Supersede any find (or other) navigation already on the shared channel with a newer cancel.
    func cancelPublishedFindNavigationOnSharedChannel() {
        let id = advanceEditorNavigationGeneration()
        editorFindHost.lastPublishedFindNavigationID = id
        editorNavigationCommand = .cancel(id: id)
    }

    private func refreshEditorFindCaretFromResponderIfPossible() {
        if let range = EditorSelectionProbe.keyWindowEditorSelection() {
            let cached = EditorFindCachedSelection(
                documentIdentity: activeEditorDocumentIdentity,
                range: range
            )
            editorFindHost.latestKnownEditorSelection = cached
            editorFindHost.controller.setCaretAnchor(range.location)
        } else if let known = editorFindHost.latestKnownEditorSelection,
                  known.documentIdentity == activeEditorDocumentIdentity
        {
            editorFindHost.controller.setCaretAnchor(known.range.location)
        }
    }

    private func currentEditorSelectionUTF16() -> NSRange {
        // Prefer live editor selection; never use cache when the find field owns focus
        // unless the cache was updated by the last applied find navigation.
        if let live = EditorSelectionProbe.keyWindowEditorSelection() {
            editorFindHost.latestKnownEditorSelection = EditorFindCachedSelection(
                documentIdentity: activeEditorDocumentIdentity,
                range: live
            )
            return live
        }
        if let known = editorFindHost.latestKnownEditorSelection,
           known.documentIdentity == activeEditorDocumentIdentity
        {
            return known.range
        }
        return NSRange(location: 0, length: 0)
    }
}

// MARK: - First-responder helpers

enum EditorFindResponderSupport {
    @MainActor
    static func keyWindowHasEditorOrFindField() -> Bool {
        if EditorSelectionProbe.keyWindowHasEditorFocus() {
            return true
        }
        guard let window = NSApp.keyWindow,
              let first = window.firstResponder
        else {
            return false
        }
        return matchesEditorOrFindFieldResponder(first)
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
