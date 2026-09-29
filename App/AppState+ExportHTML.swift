import AppKit
import Foundation
import MarkdownCore
import PreviewKit
import UniformTypeIdentifiers
import WorkspaceKit

/// Export PR F (Phase A): File › Export as HTML…
///
/// One operation is: immutable snapshot at invocation → `NSSavePanel` window sheet →
/// panel-approved destination inspection → dedicated offscreen `PreviewController` render
/// (remote images forced off before the first render) → exact `renderComplete` →
/// `exportHTML(matchingRenderID:)` → one-shot `writeExportArtifact`. Every suspension is
/// followed by a fence, and there is no suspension between the last fence and the write.
/// The visible preview, the document session, recents, and the workspace are never mutated.
@MainActor
extension AppState {
    /// Enabled only while a file-backed `.md`/`.mdx` document is current; untitled documents
    /// refuse export, as Save Copy does (`docs/export-gates.md` owner decision 2).
    var canExportCurrentDocumentAsHTML: Bool {
        hasOpenDocument
    }

    /// Starts one Export as HTML… operation and supersedes any older one. Returns the operation
    /// task so hosted tests can await it; the menu command discards it.
    @discardableResult
    func exportCurrentDocumentAsHTML() -> Task<Void, Never>? {
        let snapshot: ExportHTMLOperationSnapshot
        switch captureExportHTMLSnapshot() {
        case let .success(captured):
            snapshot = captured
        case let .failure(reason):
            presentExportHTMLResult(.stopped(reason))
            return nil
        }
        supersedeActiveExportHTMLOperation()
        exportHTMLOperations.activeOperationID = snapshot.operationID

        // Created before the panel so the bundled preview page loads while the user chooses.
        let controller = makeExportHTMLOffscreenController(for: snapshot)
        let task = Task { @MainActor [weak self] in
            var result = ExportHTMLOperationResult.stopped(.cancelled)
            if let self {
                result = await runExportHTMLOperation(snapshot, controller: controller)
            }
            // D1: the dedicated controller is released on success, failure, and cancel.
            controller.invalidate()
            self?.finishExportHTMLOperation(snapshot, result: result)
        }
        exportHTMLOperations.activeTask = task
        return task
    }

    func captureExportHTMLSnapshot() -> Result<ExportHTMLOperationSnapshot, ExportHTMLStopReason> {
        let session = currentDocument
        guard canExportCurrentDocumentAsHTML, session.fileURL != nil else {
            return .failure(.untitledDocument)
        }
        guard !hasPendingEditorSource(for: session) else {
            return .failure(.pendingEditorSource)
        }
        exportHTMLOperations.lastOperationID += 1
        return .success(ExportHTMLOperationSnapshot(
            operationID: exportHTMLOperations.lastOperationID,
            session: session,
            stateURL: sessionStateURL(for: session),
            workspaceRootURL: workspaceRootURL,
            workspaceAccess: workspaceAccess,
            theme: ExportHTMLTheme.resolve(
                preferences.previewTheme,
                appearance: NSApplication.shared.effectiveAppearance
            )
        ))
    }

    /// E1 fence: `nil` only while this exact operation is still the active one and its
    /// document, revision, URL, and workspace authority are unchanged.
    func exportHTMLStopReason(for snapshot: ExportHTMLOperationSnapshot) -> ExportHTMLStopReason? {
        guard exportHTMLOperations.activeOperationID == snapshot.operationID else {
            return .superseded
        }
        guard !Task.isCancelled else { return .cancelled }
        guard let session = snapshot.session,
              session === currentDocument,
              session.version == snapshot.textChange.version,
              session.fileKind == snapshot.textChange.fileKind,
              exportHTMLURLsMatch(session.fileURL, snapshot.textChange.fileURL),
              exportHTMLURLsMatch(sessionStateURL(for: session), snapshot.stateURL),
              !hasPendingEditorSource(for: session)
        else {
            return .documentChanged
        }
        guard exportHTMLURLsMatch(workspaceRootURL, snapshot.workspaceRootURL),
              workspaceAccess === snapshot.workspaceAccess
        else {
            return .workspaceChanged
        }
        return nil
    }

    func supersedeActiveExportHTMLOperation() {
        exportHTMLOperations.activeOperationID = nil
        exportHTMLOperations.activeTask?.cancel()
        exportHTMLOperations.activeTask = nil
        // Ends an older operation's sheet as a cancel; its fence then reports supersession.
        exportHTMLOperations.presentedPanel?.cancel(nil)
    }

    private func runExportHTMLOperation(
        _ snapshot: ExportHTMLOperationSnapshot,
        controller: PreviewController
    ) async -> ExportHTMLOperationResult {
        let destinationURL = await chooseExportHTMLDestination(for: snapshot)
        if let stop = exportHTMLStopReason(for: snapshot) { return .stopped(stop) }
        guard let destinationURL else { return .stopped(.cancelled) }

        // D5: the identity the panel approved is observed immediately after it returns and
        // becomes the only identity a confirmed overwrite may replace.
        let disposition: ExportArtifactDisposition
        switch ExportArtifactWriter.inspectDestination(at: destinationURL, kind: .html) {
        case .newLeaf:
            disposition = .createNew
        case let .existingRegularFile(identity):
            disposition = .replaceConfirmed(identity)
        case let .refused(failure):
            return .stopped(.destinationRefused(failure))
        }

        let html: String
        switch await renderStaticExportHTML(snapshot, controller: controller) {
        case let .success(rendered):
            html = rendered
        case let .failure(stop):
            return .stopped(stop)
        }

        // Final fence: no suspension separates it from this synchronous one-shot write.
        if let stop = exportHTMLStopReason(for: snapshot) { return .stopped(stop) }
        let outcome = writeExportArtifact(
            ExportArtifactWriteRequest(
                destinationURL: destinationURL,
                kind: .html,
                disposition: disposition,
                bytes: Data(html.utf8)
            ),
            exportSource: snapshot.session
        )
        return .written(outcome)
    }

    /// Renders the snapshot on the dedicated controller, waits for that exact `renderComplete`,
    /// then runs the D2 barrier. Fences after each suspension; the last fence is the final one.
    private func renderStaticExportHTML(
        _ snapshot: ExportHTMLOperationSnapshot,
        controller: PreviewController
    ) async -> Result<String, ExportHTMLStopReason> {
        let render = await controller.renderForExport(snapshot.textChange)
        if let stop = exportHTMLStopReason(for: snapshot) { return .failure(stop) }
        let renderID: Int
        switch render {
        case let .completed(completedRenderID):
            renderID = completedRenderID
        case let .failed(reason, _):
            return .failure(.renderFailed(reason: reason))
        }

        let export = await controller.exportHTML(matchingRenderID: renderID)
        if let stop = exportHTMLStopReason(for: snapshot) { return .failure(stop) }
        switch export {
        case let .ready(html, _, _):
            return .success(html)
        case let .failed(reason, _, _):
            return .failure(.renderFailed(reason: reason))
        }
    }

    private func makeExportHTMLOffscreenController(
        for snapshot: ExportHTMLOperationSnapshot
    ) -> PreviewController {
        let controller = PreviewController()
        controller.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        // D1: forced off before the first render, whatever the live-preview preference is.
        controller.setAllowsRemoteImages(false)
        controller.setTheme(snapshot.theme.rawValue)
        controller.setWorkspaceAssetRoot(snapshot.workspaceRootURL)
        exportHTMLOperations.offscreenController = controller
        return controller
    }

    private func chooseExportHTMLDestination(for snapshot: ExportHTMLOperationSnapshot) async -> URL? {
        let request = ExportHTMLDestinationRequest(
            defaultFileName: snapshot.defaultFileName,
            directoryURL: snapshot.defaultDirectoryURL
        )
        if let chooser = exportHTMLOperations.destinationChooser {
            return await chooser(request)
        }
        return await presentExportHTMLSavePanel(request)
    }

    /// A fresh panel per operation. Its URL is used once and never bookmarked or reused.
    private func presentExportHTMLSavePanel(_ request: ExportHTMLDestinationRequest) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export as HTML"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = request.defaultFileName
        panel.directoryURL = request.directoryURL
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        exportHTMLOperations.presentedPanel = panel
        defer {
            if exportHTMLOperations.presentedPanel === panel {
                exportHTMLOperations.presentedPanel = nil
            }
        }
        // A window sheet keeps the snapshot's document from being edited underneath the panel.
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return panel.runModal() == .OK ? panel.url : nil
        }
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    private func finishExportHTMLOperation(
        _ snapshot: ExportHTMLOperationSnapshot,
        result: ExportHTMLOperationResult
    ) {
        if exportHTMLOperations.activeOperationID == snapshot.operationID {
            exportHTMLOperations.activeOperationID = nil
            exportHTMLOperations.activeTask = nil
        }
        exportHTMLOperations.didFinishOperation?(snapshot.operationID, result)
        presentExportHTMLResult(result)
    }

    private func presentExportHTMLResult(_ result: ExportHTMLOperationResult) {
        guard let notice = ExportHTMLResultMessage.notice(for: result) else { return }
        presentedError = UserVisibleError(title: notice.title, message: notice.message)
    }

    private func exportHTMLURLsMatch(_ lhs: URL?, _ rhs: URL?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            exactFileURLSpellingMatches(lhs, rhs)
        default:
            false
        }
    }
}
