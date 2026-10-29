import AppKit
import EditorKit

/// Delivers in-document find commands via the AppKit responder chain (gate §6.3),
/// matching Format commands and the F0 `sendAction` proof path.
///
/// The selectors and the concrete editor type live behind `EditorFindCommandDispatcher` in
/// EditorKit (agent.md §6.1); App only consumes the delivered/not-delivered result.
///
/// Falls back to the key window's façade whenever the editor is not on the responder path
/// but the command is still eligible — the owned query field or its field editor holds
/// focus, **or** SwiftUI focus sits on the bar's own chrome. A hook invoked from a text
/// view passes that view's window, so the command cannot land on a different façade.
@MainActor
enum EditorFindCommandDelivery {
    static func installHooks() {
        EditorFindActionHooks.showFind = { window in
            facade(for: window)?.showOrRefocusEditorFind()
        }
        EditorFindActionHooks.findNext = { window in
            facade(for: window)?.editorFindNext()
        }
        EditorFindActionHooks.findPrevious = { window in
            facade(for: window)?.editorFindPrevious()
        }
        EditorFindActionHooks.useSelectionForFind = { window in
            facade(for: window)?.useSelectionForEditorFind()
        }
        EditorFindActionHooks.cancelFind = { window in
            facade(for: window)?.closeEditorFindBarFromEditorEscape() ?? false
        }
    }

    @discardableResult
    static func performShowFind() -> Bool {
        if EditorFindCommandDispatcher.send(.show) {
            return true
        }
        guard let appState = menuFacade(),
              appState.isEditorFindCommandContextActive()
        else {
            return false
        }
        appState.showOrRefocusEditorFind()
        return true
    }

    @discardableResult
    static func performFindNext() -> Bool {
        if EditorFindCommandDispatcher.send(.next) {
            return true
        }
        guard let appState = menuFacade(),
              appState.isEditorFindCommandContextActive()
        else {
            return false
        }
        appState.editorFindNext()
        return true
    }

    @discardableResult
    static func performFindPrevious() -> Bool {
        if EditorFindCommandDispatcher.send(.previous) {
            return true
        }
        guard let appState = menuFacade(),
              appState.isEditorFindCommandContextActive()
        else {
            return false
        }
        appState.editorFindPrevious()
        return true
    }

    /// Edit ▸ Find and Replace…. Uses ⌘F's eligibility and the existing query-focus receipt;
    /// there is no EditorKit selector because the App intent decides everything it needs.
    @discardableResult
    static func performShowFindAndReplace() -> Bool {
        guard let appState = menuFacade(),
              appState.hasOpenDocument,
              appState.isEditorFindCommandContextActive()
        else {
            return false
        }
        appState.showOrRefocusEditorFindAndReplace()
        return true
    }

    /// Edit ▸ Replace. Eligible only from the key window's editor or owned field editors with
    /// the bar visible and the row expanded; delivery reaches only that window's editor.
    @discardableResult
    static func performReplace() -> Bool {
        menuFacade()?.performEditorReplaceMenuCommand() != nil
    }

    /// Edit ▸ Replace All, with the same eligibility as Replace.
    @discardableResult
    static func performReplaceAll() -> Bool {
        menuFacade()?.performEditorReplaceAllMenuCommand() ?? false
    }

    @discardableResult
    static func performUseSelectionForFind() -> Bool {
        if EditorFindCommandDispatcher.send(.useSelection) {
            return true
        }
        guard let appState = menuFacade(),
              appState.isEditorFindCommandContextActive()
        else {
            return false
        }
        appState.useSelectionForEditorFind()
        return true
    }

    /// The text view's window wins. Menu fallbacks, which have no originating editor, use the
    /// key façade and do not fall back to a main window.
    private static func facade(for window: NSWindow?) -> AppState? {
        if let window, let facade = KeyWindowRouter.shared.facade(for: window) {
            return facade
        }
        return menuFacade()
    }

    private static func menuFacade() -> AppState? {
        KeyWindowRouter.shared.menuTarget(defaultFacade: nil)
    }
}
