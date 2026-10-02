import AppKit
import Foundation
import MarkdownCore
import PreviewKit
import UniformTypeIdentifiers
import WebKit
import WorkspaceKit

/// Export PR F (Phase B): File › Export as HTML…
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
        isExportHTMLFileBacked && exportHTMLDocumentWindow != nil
    }

    private var isExportHTMLFileBacked: Bool {
        currentDocument.fileURL.map { ["md", "mdx"].contains($0.pathExtension.lowercased()) } ?? false
    }

    static let exportHTMLWindowRegistered = Notification.Name("plainsong-export-document-window-registered")
    static let exportHTMLWorkspaceWindowIdentifier = NSUserInterfaceItemIdentifier("plainsong-workspace-window")

    /// An installed test provider, including nil, is authoritative.
    var exportHTMLDocumentWindow: NSWindow? {
        if let provider = exportHTMLOperations.panelWindowProvider { return provider() }
        return Self.exportHTMLDocumentWindow(key: NSApp.keyWindow, main: NSApp.mainWindow)
    }

    static func exportHTMLDocumentWindow(key: NSWindow?, main: NSWindow?) -> NSWindow? {
        if let key, key.identifier == exportHTMLWorkspaceWindowIdentifier { return key }
        if let main, main.identifier == exportHTMLWorkspaceWindowIdentifier { return main }
        return nil
    }

    /// Starts one Export as HTML… operation and supersedes any older one. Returns the operation
    /// task so hosted tests can await it; the menu command discards it.
    @discardableResult
    func exportCurrentDocumentAsHTML() -> Task<Void, Never>? {
        supersedeActiveExportHTMLOperation()
        let snapshot: ExportHTMLOperationSnapshot
        switch captureExportHTMLSnapshot() {
        case let .success(captured):
            snapshot = captured
        case let .failure(reason):
            presentExportHTMLResult(.stopped(reason))
            return nil
        }
        exportHTMLOperations.activeOperationID = snapshot.operationID
        exportHTMLOperations.contextStopReason = nil
        if let window = snapshot.window {
            exportHTMLOperations.windowCloseObserver = NotificationCenter.default
                .publisher(for: NSWindow.willCloseNotification, object: window)
                .sink { [weak self] _ in self?.noteExportHTMLContextChange(.documentChanged) }
        }

        exportHTMLStatus = .exporting(operationID: snapshot.operationID, fileName: snapshot.defaultFileName)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result: ExportHTMLOperationResult
            do {
                let controller = try await PreviewController.makeHTMLExportController(
                    websiteDataStore: exportHTMLOperations.websiteDataStoreProvider?()
                )
                defer { controller.invalidate() }
                if let stop = exportHTMLStopReason(for: snapshot) {
                    result = .stopped(stop)
                } else {
                    configureExportHTMLOffscreenController(controller, for: snapshot)
                    result = await runExportHTMLOperation(snapshot, controller: controller)
                }
            } catch {
                result = .stopped(exportHTMLStopReason(for: snapshot)
                    ?? .renderFailed(reason: "network-policy: \(error.localizedDescription)"))
            }
            finishExportHTMLOperation(snapshot, result: result)
        }
        exportHTMLOperations.activeTask = task
        return task
    }

    func captureExportHTMLSnapshot() -> Result<ExportHTMLOperationSnapshot, ExportHTMLStopReason> {
        let session = currentDocument
        guard isExportHTMLFileBacked else {
            return .failure(.untitledDocument)
        }
        guard let window = exportHTMLDocumentWindow else { return .failure(.documentChanged) }
        if let reason = exportHTMLOwnershipStopReason() { return .failure(reason) }
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
            ),
            window: window
        ))
    }

    /// E1 fence: `nil` only while this exact operation is still the active one and its
    /// document, revision, URL, and workspace authority are unchanged.
    func exportHTMLStopReason(for snapshot: ExportHTMLOperationSnapshot) -> ExportHTMLStopReason? {
        guard exportHTMLOperations.activeOperationID == snapshot.operationID else {
            return .superseded
        }
        guard !Task.isCancelled else { return .cancelled }
        if let reason = exportHTMLOperations.contextStopReason { return reason }
        if snapshot.requiresWindow, snapshot.window == nil { return .documentChanged }
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
        return exportHTMLOwnershipStopReason()
    }

    /// Records the first switch even when the owner switches back before the next await fence.
    func noteExportHTMLContextChange(_ reason: ExportHTMLStopReason) {
        guard exportHTMLOperations.activeOperationID != nil else { return }
        exportHTMLOperations.contextStopReason = exportHTMLOperations.contextStopReason ?? reason
    }

    func supersedeActiveExportHTMLOperation() {
        exportHTMLOperations.activeOperationID = nil
        exportHTMLOperations.windowCloseObserver = nil
        exportHTMLOperations.activeTask?.cancel()
        exportHTMLOperations.activeTask = nil
        exportHTMLStatus = nil
        exportHTMLOperations.offscreenController?.invalidate()
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

        if let pause = exportHTMLOperations.didInspectDestination { await pause() }
        if let stop = exportHTMLStopReason(for: snapshot) { return .stopped(stop) }

        let export: PreviewHTMLExportResult
        switch await renderStaticExportHTML(snapshot, controller: controller) {
        case let .success(rendered):
            export = rendered
        case let .failure(stop):
            return .stopped(stop)
        }

        if let pause = exportHTMLOperations.didPrepareArtifact { await pause() }

        // Final fence: no suspension separates it from this synchronous one-shot write.
        if let stop = exportHTMLStopReason(for: snapshot) { return .stopped(stop) }
        guard case let .ready(html, _, _) = export else {
            return .stopped(.renderFailed(reason: "missing-export-result"))
        }
        let request = ExportArtifactWriteRequest(
            destinationURL: destinationURL,
            kind: .html,
            disposition: disposition,
            bytes: Data(html.utf8)
        )
        let outcome: ExportArtifactWriteOutcome = if let injected = exportHTMLOperations.injectedWriteOutcome {
            injected
        } else {
            writeExportArtifact(request, exportSource: snapshot.session)
        }
        if case let .committed(commit) = outcome {
            return .exported(commit, omittedImageCount: export.omittedImageCount)
        }
        return .written(outcome)
    }

    /// Renders the snapshot on the dedicated controller, waits for that exact `renderComplete`,
    /// then runs the D2 barrier. Fences after each suspension; the last fence is the final one.
    private func renderStaticExportHTML(
        _ snapshot: ExportHTMLOperationSnapshot,
        controller: PreviewController
    ) async -> Result<PreviewHTMLExportResult, ExportHTMLStopReason> {
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
        case .ready:
            return .success(export)
        case let .failed(reason, _, _):
            return .failure(.renderFailed(reason: reason))
        }
    }

    private func configureExportHTMLOffscreenController(
        _ controller: PreviewController,
        for snapshot: ExportHTMLOperationSnapshot
    ) {
        controller.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        // D1: forced off before the first render, whatever the live-preview preference is.
        controller.setAllowsRemoteImages(false)
        controller.setTheme(snapshot.theme.rawValue)
        controller.setWorkspaceAssetRoot(snapshot.workspaceRootURL)
        exportHTMLOperations.offscreenController = controller
    }

    private func chooseExportHTMLDestination(for snapshot: ExportHTMLOperationSnapshot) async -> URL? {
        let source = snapshot.textChange.text
        let sourceURL = snapshot.textChange.fileURL
        let filenameTask = Task.detached(priority: .userInitiated) {
            ExportHTMLOperationSnapshot.defaultFileName(for: sourceURL, source: source)
        }
        let filename = await withTaskCancellationHandler {
            await filenameTask.value
        } onCancel: {
            filenameTask.cancel()
        }
        guard exportHTMLStopReason(for: snapshot) == nil else { return nil }
        exportHTMLStatus = .exporting(operationID: snapshot.operationID, fileName: filename)
        exportHTMLOperations.panelOperationID = snapshot.operationID
        defer {
            if exportHTMLOperations.panelOperationID == snapshot.operationID {
                exportHTMLOperations.panelOperationID = nil
            }
        }
        let request = ExportHTMLDestinationRequest(
            defaultFileName: filename,
            directoryURL: snapshot.defaultDirectoryURL
        )
        if let chooser = exportHTMLOperations.destinationChooser {
            return await chooser(request)
        }
        return await presentExportHTMLSavePanel(request, window: snapshot.window)
    }

    /// A fresh panel per operation. Its URL is used once and never bookmarked or reused.
    func presentExportHTMLSavePanel(
        _ request: ExportHTMLDestinationRequest, window: NSWindow?
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export as HTML"
        panel.prompt = "Export"
        panel.allowedContentTypes = UTType(filenameExtension: request.allowedExtension).map { [$0] } ?? []
        panel.nameFieldStringValue = request.defaultFileName
        panel.directoryURL = request.directoryURL
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.setAccessibilityLabel(request.accessibilityLabel)
        exportHTMLOperations.presentedPanel = panel
        defer {
            if exportHTMLOperations.presentedPanel === panel {
                exportHTMLOperations.presentedPanel = nil
            }
        }
        // Attach only to the workspace window captured at invocation; Settings/About are excluded.
        guard let window else {
            return nil
        }
        if let presenter = exportHTMLOperations.savePanelPresenter {
            return await presenter(panel, window)
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
        let isCurrent = exportHTMLOperations.activeOperationID == snapshot.operationID
        if isCurrent {
            exportHTMLOperations.activeOperationID = nil
            exportHTMLOperations.activeTask = nil
            exportHTMLOperations.offscreenController = nil
            exportHTMLOperations.windowCloseObserver = nil
            presentExportHTMLResult(result, operationID: snapshot.operationID)
        }
        exportHTMLOperations.didFinishOperation?(snapshot.operationID, result)
    }

    func presentExportHTMLResult(_ result: ExportHTMLOperationResult, operationID: UInt64 = 0) {
        exportHTMLStatus = ExportHTMLNoticeMapper.notice(for: result, operationID: operationID).map {
            .notice($0)
        }
    }

    func cancelExportHTML() {
        exportHTMLOperations.activeTask?.cancel()
        exportHTMLOperations.presentedPanel?.cancel(nil)
        exportHTMLOperations.offscreenController?.invalidate()
        exportHTMLStatus = nil
    }

    /// The export sheet changing key windows must not act as Save. Timer/explicit/termination
    /// autosaves retain their existing behavior; only this export-induced focus flush is skipped.
    func flushAutosaveAfterWindowResignedKey() {
        guard exportHTMLOperations.panelOperationID == nil else { return }
        flushAutosaveIfNeeded()
    }

    func dismissExportHTMLNotice() {
        if case .notice = exportHTMLStatus { exportHTMLStatus = nil }
    }

    private func exportHTMLOwnershipStopReason() -> ExportHTMLStopReason? {
        if hasWorkspaceMutationRecoveryLoadFailure { return .recoveryStoresUnavailable }
        for session in workspaceSaveCopyOwnershipCandidates() {
            let identity = ObjectIdentifier(session)
            if anchoredSessionFileBinding(for: session) == nil,
               indeterminateSessionWriteContexts[identity] == nil
            {
                guard case .proven? = unanchoredManagedSessionOwnershipProofs[identity] else {
                    return .unprovenDocumentOwnership
                }
            }
        }
        return nil
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
