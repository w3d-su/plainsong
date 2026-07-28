import AppKit
import EditorKit

/// Delivers in-document find commands via the AppKit responder chain (gate §6.3),
/// matching Format commands and the F0 `sendAction` proof path.
///
/// The selectors and the concrete editor type live behind `EditorFindCommandDispatcher` in
/// EditorKit (agent.md §6.1); App only consumes the delivered/not-delivered result.
/// Falls back to shared `AppState` only when the key window's first responder is the find
/// field (or its field editor), which is not on the editor's responder path.
@MainActor
enum EditorFindCommandDelivery {
    static func installHooks() {
        EditorFindActionHooks.showFind = {
            PlainsongAppServices.appState?.showOrRefocusEditorFind()
        }
        EditorFindActionHooks.findNext = {
            PlainsongAppServices.appState?.editorFindNext()
        }
        EditorFindActionHooks.findPrevious = {
            PlainsongAppServices.appState?.editorFindPrevious()
        }
        EditorFindActionHooks.useSelectionForFind = {
            PlainsongAppServices.appState?.useSelectionForEditorFind()
        }
        EditorFindActionHooks.cancelFind = {
            PlainsongAppServices.appState?.closeEditorFindBarFromEditorEscape() ?? false
        }
    }

    @discardableResult
    static func performShowFind() -> Bool {
        if EditorFindCommandDispatcher.send(.show) {
            return true
        }
        // Find field owns focus: not on the editor responder path.
        guard let appState = PlainsongAppServices.appState,
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
        guard let appState = PlainsongAppServices.appState,
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
        guard let appState = PlainsongAppServices.appState,
              appState.isEditorFindCommandContextActive()
        else {
            return false
        }
        appState.editorFindPrevious()
        return true
    }

    @discardableResult
    static func performUseSelectionForFind() -> Bool {
        if EditorFindCommandDispatcher.send(.useSelection) {
            return true
        }
        guard let appState = PlainsongAppServices.appState,
              appState.isEditorFindCommandContextActive()
        else {
            return false
        }
        appState.useSelectionForEditorFind()
        return true
    }
}
