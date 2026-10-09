import AppKit
import Foundation
import PDFKit
import PreviewKit
import UniformTypeIdentifiers
import WorkspaceKit

/// Export PR G: File › Export as PDF… and Print… on PR F's snapshot, offscreen controller,
/// and one-shot writer. PDF is panel-first, like HTML. Print renders the same snapshot in
/// the light theme, captures it with the A1 planner at the paper's imageable aspect, and
/// prints the resulting PDF through PDFKit's standard panel; AppKit owns system
/// destinations, including the panel's PDF actions (B1, `docs/export-gates.md` D4).
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

    /// While the print sheet is up the document window is busy hosting it: File ›
    /// Export…/Print… stay ineligible and `beginExport` refuses without superseding.
    var isExportPrintSheetActive: Bool {
        exportHTMLOperations.printHostWindow != nil
            || exportHTMLOperations.printCompletions.values.contains { !$0.isResolved }
    }

    func dismissExportPrintSheet() {
        if let window = exportHTMLOperations.printHostWindow, let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .cancel)
        }
        setExportPrintHostWindow(nil)
        // Finish the waiting task even if AppKit's didRun is late or never arrives; the
        // completion stays retained until didRun since the operation holds the delegate
        // weakly.
        for completion in exportHTMLOperations.printCompletions.values where !completion.isResolved {
            completion.resolve(false)
        }
    }

    /// Setting the host window changes export eligibility, so post the notification the
    /// menu snapshot listens for.
    private func setExportPrintHostWindow(_ window: NSWindow?) {
        guard exportHTMLOperations.printHostWindow !== window else { return }
        exportHTMLOperations.printHostWindow = window
        NotificationCenter.default.post(name: AppState.exportHTMLWindowRegistered, object: window)
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
        guard let printInfo = exportPrintInfo() else {
            return .stopped(.renderFailed(reason: "print-info"))
        }
        let document: ExportPDFDocument
        do {
            document = try await controller.captureExportPDF(
                pageAspect: exportPrintPageAspect(printInfo)
            )
        } catch {
            return exportPDFCaptureFailure(error, for: snapshot)
        }
        if let pause = exportHTMLOperations.didPrepareArtifact {
            await pause()
        }
        if let stop = exportHTMLStopReason(for: snapshot) {
            return .stopped(stop)
        }
        // PDFDocument is not Sendable, so parsing stays on main; the parse is lazy and
        // runs once per Print, not per keystroke.
        guard let pdfDocument = PDFDocument(data: document.data) else {
            return .stopped(.renderFailed(reason: "print-document"))
        }
        guard let window = snapshot.window else { return .stopped(.documentChanged) }
        exportHTMLOperations.printDocumentObserver?(pdfDocument)
        guard let operation = pdfDocument.printOperation(
            for: printInfo,
            scalingMode: .pageScaleToFit,
            autoRotate: false
        ) else {
            return .stopped(.renderFailed(reason: "print-operation"))
        }
        let suppressPanels = exportHTMLOperations.printPanelSuppressedForTesting
        operation.showsPrintPanel = !suppressPanels
        operation.showsProgressPanel = !suppressPanels
        exportHTMLOperations.panelOperationID = snapshot.operationID
        defer {
            if exportHTMLOperations.panelOperationID == snapshot.operationID {
                exportHTMLOperations.panelOperationID = nil
            }
        }
        let succeeded = await runExportPrintPanel(operation, window: window)
        if succeeded {
            // A completed panel run persists only the page setup the user chose — paper
            // name and size, orientation, printer — for the next Print…; the job
            // disposition, saving URL, page range and copies must not leak into a later
            // print of another document, so the rest comes from a fresh shared copy.
            let persisted = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
            let chosen = operation.printInfo
            persisted.paperName = chosen.paperName
            persisted.paperSize = chosen.paperSize
            persisted.orientation = chosen.orientation
            persisted.printer = chosen.printer
            exportHTMLOperations.lastPrintInfo = persisted
            // The job is done; an edit made while the panel was up must not read as a
            // mid-operation document change.
            return .printed
        }
        if let stop = exportHTMLStopReason(for: snapshot) {
            return .stopped(stop)
        }
        return .stopped(.cancelled)
    }

    /// A copy of the panel's last chosen print info — or the test seam's — with the
    /// imageable area the planner's page aspect comes from.
    private func exportPrintInfo() -> NSPrintInfo? {
        if let provider = exportHTMLOperations.printInfoProvider {
            return provider()
        }
        if let last = exportHTMLOperations.lastPrintInfo {
            return last.copy() as? NSPrintInfo
        }
        return NSPrintInfo.shared.copy() as? NSPrintInfo
    }

    /// Imageable height / width. `imageablePageBounds` is already orientation-aware
    /// (landscape A4 reports 783 × 559), so the ratio is used as-is.
    private func exportPrintPageAspect(_ printInfo: NSPrintInfo) -> CGFloat {
        let bounds = printInfo.imageablePageBounds
        guard bounds.width > 0, bounds.height > 0 else { return 1 }
        return bounds.height / bounds.width
    }

    /// Typed mapping for PDF capture errors: supersede/cancel first (silent), then each
    /// `ExportPDFCaptureError` case.
    func exportPDFCaptureFailure(
        _ error: Error,
        for snapshot: ExportHTMLOperationSnapshot
    ) -> ExportHTMLOperationResult {
        if let stop = exportHTMLStopReason(for: snapshot) {
            return .stopped(stop)
        }
        if error is CancellationError {
            return .stopped(.cancelled)
        }
        if let captureError = error as? ExportPDFCaptureError {
            return .stopped(.captureFailed(captureError))
        }
        return .stopped(.renderFailed(reason: "pdf-capture: \(error.localizedDescription)"))
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
            return exportPDFCaptureFailure(error, for: snapshot)
        }
        if let pause = exportHTMLOperations.didPrepareArtifact {
            await pause()
        }
        if let stop = exportHTMLStopReason(for: snapshot) {
            return .stopped(stop)
        }
        guard !document.data.isEmpty else {
            return .stopped(.captureFailed(.emptyDocument))
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
            return .exported(
                commit,
                omittedImageCount: export.omittedImageCount,
                shrunkPages: document.shrunkPages
            )
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
        setExportPrintHostWindow(window)
        // Whether didRun, a cancel, or a supersede ended the sheet, the window is free
        // to host the next export panel again.
        defer { setExportPrintHostWindow(nil) }
        return await withCheckedContinuation { continuation in
            let completion = ExportPrintCompletion { success in
                continuation.resume(returning: success)
            }
            let key = ObjectIdentifier(completion)
            completion.onDidRun = { [weak self] in
                self?.exportHTMLOperations.printCompletions.removeValue(forKey: key)
            }
            exportHTMLOperations.printCompletions[key] = completion
            operation.runModal(
                for: window,
                delegate: completion,
                didRun: #selector(ExportPrintCompletion.printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil
            )
        }
    }
}

/// The print sheet's modal callback. `resolve` resumes the awaiting task exactly once —
/// whether through AppKit's `didRun`, `dismissExportPrintSheet`, or the task's own
/// cancellation — while the registry retains the object until `didRun` actually arrives
/// because `NSPrintOperation` does not retain its delegate.
final class ExportPrintCompletion: NSObject {
    private let finish: (Bool) -> Void
    private(set) var isResolved = false
    /// Unregisters the completion from the registry; invoked only on AppKit's didRun.
    var onDidRun: (() -> Void)?

    init(_ finish: @escaping (Bool) -> Void) {
        self.finish = finish
    }

    func resolve(_ success: Bool) {
        guard !isResolved else { return }
        isResolved = true
        finish(success)
    }

    @objc func printOperationDidRun(
        _: NSPrintOperation, success: Bool, contextInfo _: UnsafeMutableRawPointer?
    ) {
        onDidRun?()
        resolve(success)
    }
}
