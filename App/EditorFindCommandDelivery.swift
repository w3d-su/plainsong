import AppKit
import EditorKit
import STTextView

/// Delivers in-document find commands via the AppKit responder chain (gate §6.3),
/// matching Format commands and the F0 `sendAction` proof path.
///
/// Falls back to shared `AppState` only when the key window's first responder is the
/// find field (or its field editor), which is not an `STTextView` target.
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
    }

    @discardableResult
    static func performShowFind() -> Bool {
        if NSApp.sendAction(#selector(STTextView.plainsongShowFind(_:)), to: nil, from: nil) {
            return true
        }
        // Find field owns focus: not on the STTextView responder path.
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
        if NSApp.sendAction(#selector(STTextView.plainsongFindNext(_:)), to: nil, from: nil) {
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
        if NSApp.sendAction(#selector(STTextView.plainsongFindPrevious(_:)), to: nil, from: nil) {
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
        if NSApp.sendAction(
            #selector(STTextView.plainsongUseSelectionForFind(_:)),
            to: nil,
            from: nil
        ) {
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
