import AppKit
import Combine
import EditorKit
import MarkdownCore
import SwiftUI

extension AppState {
    var isPreviewVisible: Bool {
        layoutMode.showsPreview
    }

    func requestEditorFocus() {
        storeEditorFocusRequestID(editorFocusRequestID + 1)
    }

    var isExperimentalWYSIWYGAvailable: Bool {
        preferences.experimentalWYSIWYGEnabled && isWYSIWYGMechanismHealthy
    }

    var shouldUseWYSIWYGPresentation: Bool {
        layoutMode.usesWYSIWYGPresentation && isExperimentalWYSIWYGAvailable
    }

    var layoutModeCommandTitle: String {
        switch layoutMode {
        case .sourcePreview:
            "Show Source Only"
        case .sourceOnly:
            isExperimentalWYSIWYGAvailable ? "Show WYSIWYG (Experimental)" : "Show Preview"
        case .wysiwyg:
            "Show Source + Preview"
        }
    }

    var layoutModeToolbarTitle: String {
        switch layoutMode {
        case .sourcePreview:
            "Source Only"
        case .sourceOnly:
            isExperimentalWYSIWYGAvailable ? "WYSIWYG" : "Preview"
        case .wysiwyg:
            "Source + Preview"
        }
    }

    var layoutModeToolbarSystemImage: String {
        switch layoutMode {
        case .sourcePreview:
            "doc.text"
        case .sourceOnly:
            isExperimentalWYSIWYGAvailable ? "textformat" : "sidebar.right"
        case .wysiwyg:
            "sidebar.right"
        }
    }

    var layoutModeToolbarHelp: String {
        isExperimentalWYSIWYGAvailable
            ? "Cycle layout: source + preview, source only, WYSIWYG (Experimental)"
            : "Toggle layout between source + preview and source only"
    }

    func cycleLayoutMode() {
        setLayoutMode(layoutMode.next(isWYSIWYGAvailable: isExperimentalWYSIWYGAvailable))
    }

    func togglePreview() {
        cycleLayoutMode()
    }

    func setPreviewVisible(_ isVisible: Bool) {
        setLayoutMode(isVisible ? .sourcePreview : .sourceOnly)
    }

    func setLayoutMode(_ requestedMode: EditorLayoutMode) {
        let resolvedMode = resolveLayoutModeForCurrentAvailability(requestedMode)
        // The request was honored as-is (no WYSIWYG downgrade), so any earlier
        // fallback notice is stale — clear it once the user lands where they asked.
        if resolvedMode == requestedMode {
            dismissWYSIWYGFallbackMessage()
        }
        guard layoutMode != resolvedMode else {
            persistLayoutMode(resolvedMode)
            return
        }

        storeLayoutMode(resolvedMode)
        persistLayoutMode(resolvedMode)
    }

    func dismissWYSIWYGFallbackMessage() {
        guard wysiwygFallbackMessage != nil else { return }
        storeWYSIWYGFallbackMessage(nil)
    }

    func handleWYSIWYGMechanismFailure(_ reason: String) {
        guard isWYSIWYGMechanismHealthy || layoutMode == .wysiwyg else { return }

        storeWYSIWYGMechanismHealthy(false)
        recoverFromUnavailableWYSIWYG(reason: reason)
    }

    func observeCurrentDocument() {
        documentChangeCancellable?.cancel()
        documentChangeCancellable = shownSession.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func handlePreferencesChanged() {
        reconcileLayoutModeAvailability()
        objectWillChange.send()
        scheduleAutosave()
    }

    private func reconcileLayoutModeAvailability() {
        guard layoutMode == .wysiwyg, !isExperimentalWYSIWYGAvailable else { return }

        let reason = preferences.experimentalWYSIWYGEnabled
            ? "WYSIWYG editor mechanism is unhealthy"
            : "Experimental WYSIWYG is disabled"
        recoverFromUnavailableWYSIWYG(reason: reason)
    }

    private func resolveLayoutModeForCurrentAvailability(_ requestedMode: EditorLayoutMode) -> EditorLayoutMode {
        guard requestedMode == .wysiwyg, !isExperimentalWYSIWYGAvailable else {
            return requestedMode
        }

        let reason = preferences.experimentalWYSIWYGEnabled
            ? "WYSIWYG editor mechanism is unhealthy"
            : "Experimental WYSIWYG is disabled"
        recordWYSIWYGFallback(reason: reason)
        return .sourceOnly
    }

    private func recoverFromUnavailableWYSIWYG(reason: String) {
        recordWYSIWYGFallback(reason: reason)
        guard layoutMode != .sourceOnly else {
            persistLayoutMode(.sourceOnly)
            return
        }

        storeLayoutMode(.sourceOnly)
        persistLayoutMode(.sourceOnly)
    }

    private func recordWYSIWYGFallback(reason: String) {
        let message = "\(reason); falling back to source-only layout without changing source text."
        storeWYSIWYGFallbackMessage(message)
        NSLog("[Plainsong] %@", message)
    }

    private func persistLayoutMode(_ mode: EditorLayoutMode) {
        userDefaults.set(mode.rawValue, forKey: Self.layoutModeDefaultsKey)
    }
}
