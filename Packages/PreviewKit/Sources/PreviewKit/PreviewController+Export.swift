import Foundation
import MarkdownCore

extension PreviewController {
    /// D1: call only on a dedicated offscreen controller with remote images disabled,
    /// never the visible pane's controller. Its owner must invalidate it on completion.
    public func exportHTML(matchingRenderID renderID: Int) async -> PreviewHTMLExportResult {
        let exportID = nextExportID
        nextExportID += 1
        guard !Task.isCancelled else {
            return .failed(reason: "cancelled", exportID: exportID, renderID: renderID)
        }
        guard isReady, renderID == scrollDeliveryState.completedRenderID else {
            return .failed(reason: "stale-or-missing-render", exportID: exportID, renderID: renderID)
        }
        failPendingHTMLExport(reason: "superseded")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .failed(reason: "cancelled", exportID: exportID, renderID: renderID))
                    return
                }
                pendingHTMLExport = PendingHTMLExport(
                    exportID: exportID, renderID: renderID, continuation: continuation
                )
                let timeout = exportTimeoutNanoseconds
                pendingHTMLExport?.timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: timeout) } catch { return }
                    self?.failPendingHTMLExport(reason: "timeout", matchingExportID: exportID)
                }
                // Reuse MarkdownCore's YAML parser only on export, off the typing path.
                let source = exportSourceText
                pendingHTMLExport?.preparationTask = Task.detached { [weak self] in
                    let parsed = Frontmatter.parse(source)
                    let title = parsed.error == nil ? parsed.block?.fieldValues["title"]?.stringValue : nil
                    guard !Task.isCancelled else { return }
                    await self?.beginHTMLExport(exportID: exportID, title: title)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.failPendingHTMLExport(reason: "cancelled", matchingExportID: exportID)
            }
        }
    }

    private func beginHTMLExport(exportID: Int, title: String?) {
        guard pendingHTMLExport?.exportID == exportID else { return }
        pendingHTMLExport?.documentTitle = title
        guard let pending = pendingHTMLExport else { return }
        sendExportRequest(pending, phase: .discovery)
    }

    private func sendExportRequest(
        _ pending: PendingHTMLExport,
        phase: ExportHTMLPhase,
        outcomes: [ExportResourceOutcome] = []
    ) {
        send(.exportHTML(ExportHTMLPayload(
            exportID: pending.exportID, renderID: pending.renderID, phase: phase,
            documentTitle: pending.documentTitle, resourceOutcomes: outcomes
        ))) { [weak self] succeeded in
            if !succeeded {
                self?.failPendingHTMLExport(reason: "bridge-send-failed", matchingExportID: pending.exportID)
            }
        }
    }

    func handleExportHTMLResult(_ payload: ExportHTMLResultPayload) {
        guard let pending = pendingHTMLExport,
              pending.exportID == payload.exportID,
              pending.renderID == payload.renderID
        else { return }
        switch payload.state {
        case let .resourcesNeeded(resources):
            guard pending.phase == .discovery else {
                failPendingHTMLExport(reason: "invalid-export-phase")
                return
            }
            pendingHTMLExport?.phase = .finalization
            sendExportRequest(pending, phase: .finalization, outcomes: resources.map { .omit($0) })
        case let .ready(html):
            guard pending.phase == .finalization else {
                failPendingHTMLExport(reason: "invalid-export-phase")
                return
            }
            finishHTMLExport(.ready(html: html, exportID: payload.exportID, renderID: payload.renderID))
        case let .failed(reason):
            failPendingHTMLExport(reason: reason)
        }
    }

    func failPendingHTMLExport(reason: String, matchingExportID: Int? = nil) {
        guard let pending = pendingHTMLExport,
              matchingExportID == nil || matchingExportID == pending.exportID
        else { return }
        finishHTMLExport(.failed(reason: reason, exportID: pending.exportID, renderID: pending.renderID))
    }

    private func finishHTMLExport(_ result: PreviewHTMLExportResult) {
        guard let pending = pendingHTMLExport else { return }
        pendingHTMLExport = nil
        pending.timeoutTask?.cancel()
        pending.preparationTask?.cancel()
        pending.continuation.resume(returning: result)
    }
}

struct PendingHTMLExport {
    let exportID: Int
    let renderID: Int
    let continuation: CheckedContinuation<PreviewHTMLExportResult, Never>
    var phase: ExportHTMLPhase = .discovery
    var documentTitle: String?
    var timeoutTask: Task<Void, Never>?
    var preparationTask: Task<Void, Never>?
}
