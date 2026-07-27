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
    func ensureEditorFindSessionObserverInstalled() {
        guard !editorFindHost.didInstallSessionObserver else { return }
        editorFindHost.didInstallSessionObserver = true
        editorFindHost.controller.onSessionDidChange = { [weak self] in
            guard let self else { return }
            self.publishEditorFindSessionPresentation()
            self.applyEditorFindNavigationIfNeeded()
        }
    }

    /// Whether the key window's first responder is the editor, its field editor, or the find field.
    func isEditorFindCommandContextActive() -> Bool {
        guard hasOpenDocument else { return false }
        return EditorFindResponderSupport.keyWindowHasEditorOrFindField()
    }

    /// ⌘F — show or re-focus; never closes.
    func showOrRefocusEditorFind() {
        guard hasOpenDocument else { return }
        // Allow when bar already open (focus may be in find field) or editor is active.
        let contextOK = isEditorFindCommandContextActive() || editorFindHost.ui.isBarVisible
        guard contextOK else { return }

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
        ui.closeBar()
        setEditorFindUI(ui)
        requestEditorFocus()
    }

    func editorFindNext() {
        guard hasOpenDocument else { return }
        guard editorFindHost.ui.isBarVisible || isEditorFindCommandContextActive() else { return }
        ensureEditorFindSessionObserverInstalled()
        refreshEditorFindCaretFromResponderIfPossible()
        if !editorFindHost.ui.isBarVisible {
            syncEditorFindControllerDocument()
        }
        if editorFindHost.controller.session == nil {
            if !editorFindHost.ui.queryText.isEmpty {
                pushEditorFindQueryToController()
            }
            return
        }
        editorFindHost.controller.findNext()
        applyEditorFindNavigationIfNeeded()
        publishEditorFindSessionPresentation()
    }

    func editorFindPrevious() {
        guard hasOpenDocument else { return }
        guard editorFindHost.ui.isBarVisible || isEditorFindCommandContextActive() else { return }
        ensureEditorFindSessionObserverInstalled()
        refreshEditorFindCaretFromResponderIfPossible()
        if !editorFindHost.ui.isBarVisible {
            syncEditorFindControllerDocument()
        }
        if editorFindHost.controller.session == nil {
            if !editorFindHost.ui.queryText.isEmpty {
                pushEditorFindQueryToController()
            }
            return
        }
        editorFindHost.controller.findPrevious()
        applyEditorFindNavigationIfNeeded()
        publishEditorFindSessionPresentation()
    }

    /// ⌘E — macOS convention: set pattern from selection **without** showing/focusing the bar.
    /// Never closes an open bar. Format ▸ Inline Code no longer claims ⌘E (Decision Log).
    func useSelectionForEditorFind() {
        guard hasOpenDocument else { return }
        guard isEditorFindCommandContextActive() || editorFindHost.ui.isBarVisible else { return }

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
        pushEditorFindQueryToController()
        if editorFindHost.ui.isBarVisible {
            publishEditorFindSessionPresentation()
        }
    }

    func handleEditorFindQueryTextChange(_ text: String) {
        ensureEditorFindSessionObserverInstalled()
        var ui = editorFindHost.ui
        ui.queryText = text
        setEditorFindUI(ui)
        syncEditorFindControllerDocument()
        if let selection = editorFindHost.latestKnownEditorSelection {
            editorFindHost.controller.setCaretAnchor(selection.location)
        }
        pushEditorFindQueryToController()
    }

    func handleEditorFindOptionsChange() {
        ensureEditorFindSessionObserverInstalled()
        syncEditorFindControllerDocument()
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

    func notifyEditorFindDocumentDidSwitch() {
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
            // Do **not** call `setQuery` / `pushEditorFindQueryToController` here — that
            // would schedule `.query` and auto-jump into the newly focused file (F4b).
            editorFindHost.controller.rebindDocument(binding)
        } else if editorFindHost.controller.query != nil {
            editorFindHost.controller.rebindDocument(binding)
        }
    }

    func notifyEditorFindWorkspaceDidClose() {
        editorFindHost.controller.clearForNoDocument()
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
        // Do not sleep-then-apply: that races match completion and leaves hits unmarked.
    }

    private func publishEditorFindSessionPresentation() {
        var ui = editorFindHost.ui
        ui.applySessionPresentation(editorFindHost.controller.session)
        setEditorFindUI(ui)
    }

    private func applyEditorFindNavigationIfNeeded() {
        guard let command = editorFindHost.controller.pendingNavigationCommand else { return }
        let id = command.id
        if let last = editorFindHost.lastAppliedNavigationID, id <= last {
            return
        }
        editorFindHost.lastAppliedNavigationID = id
        // Bump by reassigning so SwiftUI/EditorKit always observe a new command value
        // even if a prior equal enum associated value was somehow sticky.
        editorNavigationCommand = nil
        editorNavigationCommand = command
    }

    private func refreshEditorFindCaretFromResponderIfPossible() {
        if let range = EditorSelectionProbe.keyWindowEditorSelection() {
            editorFindHost.latestKnownEditorSelection = range
            editorFindHost.controller.setCaretAnchor(range.location)
        } else if let known = editorFindHost.latestKnownEditorSelection {
            editorFindHost.controller.setCaretAnchor(known.location)
        }
    }

    private func currentEditorSelectionUTF16() -> NSRange {
        if let live = EditorSelectionProbe.keyWindowEditorSelection() {
            editorFindHost.latestKnownEditorSelection = live
            return live
        }
        if let known = editorFindHost.latestKnownEditorSelection {
            return known
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
