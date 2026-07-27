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
    ///
    /// Fences the controller first: a query typed moments earlier may still be inside the
    /// debounce window, and its match would otherwise land after the bar is gone and move
    /// the editor selection. The retained query stays usable for a later ⌘G.
    func closeEditorFindBar() {
        guard editorFindHost.ui.isBarVisible else { return }
        var ui = editorFindHost.ui
        ui.closeBar() // also supersedes pending focus
        setEditorFindUI(ui)
        yieldEditorFindNavigation(caretAnchorUTF16: nil)
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

    /// Consumes a focus request after the **key** window's owned query field is the real
    /// first responder. Shared across the `WindowGroup` so a background window or a
    /// remounted bar cannot replay a spent token. Idempotent for older/applied tokens.
    func markEditorFindFocusApplied(_ requestID: UInt64) {
        guard requestID == editorFindHost.ui.focusRequestID,
              EditorFindFocusArbitration.shouldApplyFocus(
                  requestID: requestID,
                  appliedID: editorFindHost.ui.focusAppliedID,
                  supersededID: editorFindHost.ui.focusSupersededID,
                  isKeyWindow: true
              )
        else {
            return
        }
        var ui = editorFindHost.ui
        ui.focusAppliedID = requestID
        setEditorFindUI(ui)
    }

    enum EditorFindStepDirection {
        case next
        case previous
    }

    func editorFindNext() {
        guard isEditorFindCommandContextActive() else { return }
        stepEditorFind(.next)
    }

    func editorFindPrevious() {
        guard isEditorFindCommandContextActive() else { return }
        stepEditorFind(.previous)
    }

    /// Next/previous triggered by the find bar's own chrome (buttons, Return in the field).
    ///
    /// Deliberately skips `isEditorFindCommandContextActive()`. That guard keeps *menu*
    /// commands from firing when window focus is somewhere unrelated; a click or Return on
    /// the bar is already unambiguous, and with Full Keyboard Access the focused control
    /// may be a bar toggle or button that the responder check does not recognize.
    func stepEditorFindFromBarControl(_ direction: EditorFindStepDirection) {
        stepEditorFind(direction)
    }

    private func stepEditorFind(_ direction: EditorFindStepDirection) {
        guard hasOpenDocument else { return }
        ensureEditorFindSessionObserverInstalled()
        refreshEditorFindCaretFromResponderIfPossible()
        if !editorFindHost.ui.isBarVisible {
            syncEditorFindControllerDocument()
        }
        // While session is nil (debounce), records a pending step intent bound to the
        // in-flight query generation — does not re-push the query.
        switch direction {
        case .next: editorFindHost.controller.findNext()
        case .previous: editorFindHost.controller.findPrevious()
        }
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
        // Deliberately no selection-cache write here. Publishing is not applying: EditorKit
        // may leave the request pending (marked text, document not installed) or reject it
        // outright, so ⌘E reads the editor's *applied* selection instead
        // (`currentEditorSelectionUTF16`).
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
        if let range = appliedEditorSelectionUTF16() {
            editorFindHost.controller.setCaretAnchor(range.location)
        } else if let known = editorFindHost.latestKnownEditorSelection,
                  known.documentIdentity == activeEditorDocumentIdentity
        {
            editorFindHost.controller.setCaretAnchor(known.range.location)
        }
    }

    /// The editor's real selection, caching it for the window-less fallback.
    ///
    /// Reads the editor view itself rather than the last *published* navigation: a published
    /// request can still be pending or rejected inside EditorKit, so trusting it would let
    /// ⌘E copy a range the editor never applied.
    private func appliedEditorSelectionUTF16() -> NSRange? {
        let range = EditorSelectionProbe.keyWindowEditorSelection()
            ?? EditorSelectionProbe.keyWindowAppliedEditorSelection()
        guard let range else { return nil }
        editorFindHost.latestKnownEditorSelection = EditorFindCachedSelection(
            documentIdentity: activeEditorDocumentIdentity,
            range: range
        )
        return range
    }

    private func currentEditorSelectionUTF16() -> NSRange {
        if let applied = appliedEditorSelectionUTF16() {
            return applied
        }
        if let known = editorFindHost.latestKnownEditorSelection,
           known.documentIdentity == activeEditorDocumentIdentity
        {
            return known.range
        }
        return NSRange(location: 0, length: 0)
    }
}
