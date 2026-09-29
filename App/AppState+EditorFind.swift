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
    ///
    /// The bar's toggles and buttons cannot be resolved in AppKit — SwiftUI flattens them and
    /// the editor into one hosting view — so focus on those arrives from SwiftUI as a
    /// per-window entry in `chromeFocusByWindow`, and only the **key** window's own entry
    /// counts. Anything else — bar hidden, or no entry for the key window — falls through to
    /// the AppKit responder check.
    ///
    /// Residual: if SwiftUI ever failed to clear its own focus when focus left the bar, a find
    /// command could fire while focus sits elsewhere in that same window. That is bounded to
    /// one window and one document, and is strictly less harmful than the alternative — the
    /// commands and the bar's own buttons going dead under Full Keyboard Access.
    func isEditorFindCommandContextActive() -> Bool {
        guard hasOpenDocument else { return false }
        if let override = editorFindHost.commandContextOverride {
            return override
        }
        if editorFindHost.ui.isBarVisible, hasKeyWindowFindChromeFocus() {
            return true
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
    /// Suspends rather than re-runs: a query still inside the debounce window must not land
    /// afterwards and move the editor selection, but a **resolved** session keeps its ordinal
    /// so a later ⌘G continues from the match the user was on instead of restarting at the
    /// caret anchor.
    func closeEditorFindBar() {
        guard editorFindHost.ui.isBarVisible else { return }
        var ui = editorFindHost.ui
        ui.closeBar() // also supersedes pending focus
        setEditorFindUI(ui)
        clearEditorFindChromeFocus()
        cancelPublishedFindNavigationOnSharedChannel()
        editorFindHost.controller.suspendNavigation()
        requestEditorFocus()
    }

    /// Escape delivered to the **editor** (`MarkdownSTTextView.cancelOperation`).
    ///
    /// Returns `false` when there is no bar to close, so the editor keeps its own Escape
    /// behaviour. EditorKit has already ruled out marked text and an open completion list.
    @discardableResult
    func closeEditorFindBarFromEditorEscape() -> Bool {
        guard editorFindHost.ui.isBarVisible else { return false }
        closeEditorFindBar()
        return true
    }

    /// Escape delivered to find-bar chrome (SwiftUI `onExitCommand`).
    ///
    /// This is a responder-chain action, **not** a key equivalent: a key equivalent is
    /// resolved before the field editor sees the event, which is exactly how the Done button's
    /// old `.cancelAction` closed the bar mid-IME-composition. The composition guard is still
    /// re-checked here, because a field editor that declines `cancelOperation:` lets the event
    /// bubble up to this handler.
    func closeEditorFindBarFromExitCommand() {
        guard editorFindHost.ui.isBarVisible,
              !EditorFindResponderSupport.keyWindowQueryFieldIsComposing()
        else {
            return
        }
        closeEditorFindBar()
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

    /// Consumes a select-all request after the **key** window's owned query field performed
    /// it. Shared for the same reason as the focus receipt: a fresh coordinator in a second
    /// window starts at zero and would otherwise replay a spent select-all, so the user's
    /// next keystroke would replace the whole query.
    func markEditorFindSelectAllApplied(_ requestID: UInt64) {
        guard requestID == editorFindHost.ui.selectAllRequestID,
              requestID > 0,
              requestID > editorFindHost.ui.selectAllAppliedID
        else {
            return
        }
        var ui = editorFindHost.ui
        ui.selectAllAppliedID = requestID
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
        if let known = usableCachedEditorSelection() {
            editorFindHost.controller.setCaretAnchor(known.location)
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

    /// Find-match decoration for the focused editor (docs/editor-find-gates.md F8).
    ///
    /// Cached beside the controller rather than mirrored into `EditorFindUIState`: a query can
    /// retain up to `EditorFindLimits.retainedMatchCeiling` matches. Materializing that array
    /// from the controller on every `WorkspaceWindow.body` evaluation would put O(matches)
    /// work on unrelated editor updates; putting it in the diffed UI state would make every
    /// unrelated chrome update compare it.
    ///
    /// `nil` while the bar is closed, so closing find clears decoration instead of leaving the
    /// last query lit behind a hidden bar.
    var editorFindMatchHighlight: EditorFindMatchHighlightRequest? {
        guard editorFindHost.ui.isBarVisible else { return nil }
        return editorFindHost.matchHighlightRequest
    }

    private func publishEditorFindSessionPresentation() {
        if let session = editorFindHost.controller.session,
           !session.query.pattern.isEmpty,
           !session.matches.isEmpty
        {
            editorFindHost.matchHighlightRequest = EditorFindMatchHighlightRequest(
                generation: editorFindHost.controller.queryGeneration,
                matches: session.matches.map(\.range),
                // `currentOrdinal` is the 1-based UI ordinal; the request wants a 0-based index.
                currentIndex: session.currentOrdinal.map { $0 - 1 }
            )
        } else {
            editorFindHost.matchHighlightRequest = nil
        }
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
}
