import AppKit
import Foundation
import PreviewKit
import UniformTypeIdentifiers
import WorkspaceKit

/// Export PR G: File › Export as PDF… and Print… on PR F's snapshot, offscreen controller,
/// and one-shot writer. PDF is panel-first, like HTML. Print renders first, then shows
/// the standard panel; AppKit owns system destinations, including the panel's PDF actions.
@MainActor
extension AppState {
    @discardableResult
    func exportCurrentDocumentAsPDF() -> Task<Void, Never>? {
        beginExport(.pdf)
    }

    @discardableResult
    func printCurrentDocument() -> Task<Void, Never>? {
        beginExport(.print)
    }

    func dismissExportPrintSheet() {
        if let window = exportHTMLOperations.printHostWindow, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .cancel)
        }
        exportHTMLOperations.printHostWindow = nil
        exportHTMLOperations.printCompletion = nil
    }

    func runExportPrint(
        _ snapshot: ExportHTMLOperationSnapshot,
        controller: PreviewController
    ) async -> ExportHTMLOperationResult {
        let rendered: PreviewHTMLExportResult
        switch await renderStaticExportHTML(snapshot, controller: controller) {
        case let .success(export):
            rendered = export
        case let .failure(stop):
            return .stopped(stop)
        }
        guard case .ready = rendered else {
            return .stopped(.renderFailed(reason: "missing-export-result"))
        }
        if let stop = exportHTMLStopReason(for: snapshot) {
            return .stopped(stop)
        }
        let operation: NSPrintOperation
        do {
            operation = try await controller.makeExportPrintOperation()
        } catch {
            return .stopped(.renderFailed(reason: "print-prepare: \(error)"))
        }
        if let stop = exportHTMLStopReason(for: snapshot) {
            return .stopped(stop)
        }
        guard let window = snapshot.window else { return .stopped(.documentChanged) }
        guard controller.webView.window == nil else {
            return .stopped(.renderFailed(reason: "print-mounted-webview"))
        }
        exportHTMLOperations.panelOperationID = snapshot.operationID
        defer {
            if exportHTMLOperations.panelOperationID == snapshot.operationID {
                exportHTMLOperations.panelOperationID = nil
            }
        }
        let succeeded = await runExportPrintPanel(operation, window: window)
        if let stop = exportHTMLStopReason(for: snapshot) {
            return .stopped(stop)
        }
        return succeeded ? .printed : .stopped(.cancelled)
    }

    func writeExportPDF(
        _ snapshot: ExportHTMLOperationSnapshot,
        controller: PreviewController,
        destinationURL: URL,
        disposition: ExportArtifactDisposition,
        export: PreviewHTMLExportResult
    ) async -> ExportHTMLOperationResult {
        let document: ExportPDFDocument
        do {
            document = try await controller.captureExportPDF()
        } catch {
            return .stopped(.renderFailed(reason: "pdf-capture"))
        }
        if let pause = exportHTMLOperations.didPrepareArtifact {
            await pause()
        }
        if let stop = exportHTMLStopReason(for: snapshot) {
            return .stopped(stop)
        }
        guard !document.data.isEmpty else {
            return .stopped(.renderFailed(reason: "pdf-capture"))
        }
        let request = ExportArtifactWriteRequest(
            destinationURL: destinationURL, kind: .pdf, disposition: disposition, bytes: document.data
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

    /// A fresh panel per operation. Its URL is used once and never bookmarked or reused.
    func presentExportHTMLSavePanel(
        _ request: ExportHTMLDestinationRequest, window: NSWindow?
    ) async -> URL? {
        let panel = NSSavePanel()
        let isPDF = request.allowedExtension == "pdf"
        panel.title = isPDF ? "Export as PDF" : "Export as HTML"
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
        guard let window else { return nil }
        if let presenter = exportHTMLOperations.savePanelPresenter {
            return await presenter(panel, window)
        }
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    func exportHTMLOwnershipStopReason() -> ExportHTMLStopReason? {
        if hasWorkspaceMutationRecoveryLoadFailure {
            return .recoveryStoresUnavailable
        }
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

    func exportHTMLURLsMatch(_ lhs: URL?, _ rhs: URL?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            exactFileURLSpellingMatches(lhs, rhs)
        default:
            false
        }
    }

    private func runExportPrintPanel(_ operation: NSPrintOperation, window: NSWindow) async -> Bool {
        if let runner = exportHTMLOperations.printOperationRunner {
            return await runner(operation, window)
        }
        exportHTMLOperations.printHostWindow = window
        return await withCheckedContinuation { continuation in
            let completion = ExportPrintCompletion { success in
                continuation.resume(returning: success)
            }
            exportHTMLOperations.printCompletion = completion
            operation.runModal(
                for: window,
                delegate: completion,
                didRun: #selector(ExportPrintCompletion.printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil
            )
        }
    }
}

/// Retains the print sheet's completion until AppKit calls back. The registry holds it.
final class ExportPrintCompletion: NSObject {
    private let finish: (Bool) -> Void

    init(_ finish: @escaping (Bool) -> Void) {
        self.finish = finish
    }

    @objc func printOperationDidRun(
        _: NSPrintOperation, success: Bool, contextInfo _: UnsafeMutableRawPointer?
    ) {
        finish(success)
    }
}
