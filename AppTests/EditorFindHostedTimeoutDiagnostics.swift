import AppKit
@testable import EditorKit
import Foundation
@testable import Plainsong

@MainActor
extension EditorFindHostedGateTests {
    /// Weakly registered fixture state: diagnostics must not keep a hosted app or view alive.
    func hostedFindTimeoutState(_ appState: AppState) -> String {
        let session = appState.currentDocument
        let identity = ObjectIdentifier(session)
        let ui = appState.editorFindHost.ui
        let match = appState.editorFindHost.controller.session?.currentMatch?.range
        var lines = [
            "document=\(String(describing: session.fileURL)) revision=\(session.version)",
            "currentMatch=\(String(describing: match)) total=\(String(describing: appState.editorFindHost.controller.session?.total)) queryGeneration=\(appState.editorFindHost.controller.queryGeneration)",
            "focusRequestID=\(ui.focusRequestID) focusAppliedID=\(ui.focusAppliedID) focusSupersededID=\(ui.focusSupersededID) barVisible=\(ui.isBarVisible)",
            "appNavigation=\(String(describing: appState.editorNavigationCommand)) controllerNavigation=\(String(describing: appState.editorFindHost.controller.pendingNavigationCommand))",
            "diskInspectionPending=\(appState.externalDiskInspectionTasks[identity] != nil) reloadPending=\(appState.externalReloadTasks[identity] != nil) convergencePending=\(appState.pendingExternalReloadApplications[identity] != nil)",
            "externalPrompt=\(String(describing: appState.externalChangePrompt?.fileURL)) pendingExternalText=\(session.fileURL.flatMap { appState.pendingExternalTexts[$0] } != nil)",
            "replaceAuthorization=\(appState.editorReplaceAuthorizationDecision(for: session)) liveInstallations=\(appState.liveEditorDocumentBindingInstallations(for: session))",
            "actualKeyWindow=\(String(describing: NSApp.keyWindow?.windowNumber)) replaceKeyWindow=\(String(describing: EditorReplaceCommandDispatcher.keyWindow?.windowNumber)) findKeyWindow=\(String(describing: appState.editorFindKeyWindow()?.windowNumber))",
            "replaceBatch isPreparing=\(appState.editorFindHost.replaceBatch.isPreparing) isApplying=\(appState.editorFindHost.replaceBatch.isApplying) preparationTask=\(appState.editorFindHost.replaceBatch.preparationTask != nil) lastResult=\(String(describing: appState.editorFindHost.replaceBatch.lastResult))",
            "replaceStatus=\(String(describing: appState.editorFindHost.replaceStatus)) replaceStatusSerial=\(appState.editorFindHost.replaceStatusSerial) authorityGeneration=\(appState.editorReplaceAuthorityGeneration)",
            "replaceRow validity=\(ui.replacementValidity) rowActive=\(ui.isReplaceRowActive) expanded=\(ui.isReplaceExpanded) truncated=\(ui.isTruncated) replacement=\(ui.replacementText)",
        ]
        #if DEBUG
            lines.append("navigationWrites (oldest first):")
            lines.append(contentsOf: appState.editorNavigationChannel.writeHistory)
            lines.append("replaceBarTrace (oldest first):")
            lines.append(contentsOf: appState.editorFindHost.replaceBarTrace)
        #endif
        for window in NSApp.windows {
            guard let editor = editorTextView(in: window) else { continue }
            let coordinator = editor.textDelegate as? MarkdownTextViewCoordinator
            let applied = appliedRange(in: window)
            let queryField = findQueryField(in: window)
            lines
                .append(
                    "window=\(window.windowNumber) key=\(window.isKeyWindow) responder=\(String(describing: window.firstResponder)) queryMounted=\(queryField != nil) queryOwnsResponder=\(isFindFieldFirstResponder(in: window))"
                )
            lines
                .append(
                    "appliedSelection=\(String(describing: applied)) selectionMatches=\(match != nil && applied == match) focusReceiptMatches=\(ui.focusAppliedID == ui.focusRequestID)"
                )
            lines
                .append(
                    "installation=\(String(describing: coordinator?.currentDocumentBindingInstallation)) pendingNavigation=\(String(describing: coordinator?.navigationState.pendingRequest)) highlightRevision=\(String(describing: coordinator?.lastAppliedHighlightRevision)) wysiwygInstalled=\(editor.wysiwygZeroWidthContentStorageDelegate != nil) markedText=\(editor.hasMarkedText())"
                )
        }
        return lines.joined(separator: "\n")
    }
}
