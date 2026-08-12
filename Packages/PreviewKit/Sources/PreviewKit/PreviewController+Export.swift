import Foundation

extension PreviewController {
    public func exportHTML(matchingRenderID renderID: Int) async -> PreviewHTMLExportResult {
        let exportID = nextExportID
        nextExportID += 1

        guard isReady, renderID >= 0, renderID == latestCompletedRenderID else {
            return .failed(reason: "stale-or-missing-render", exportID: exportID, renderID: renderID)
        }

        failPendingHTMLExport(reason: "superseded")

        return await withCheckedContinuation { continuation in
            pendingHTMLExport = PendingHTMLExport(
                exportID: exportID,
                renderID: renderID,
                continuation: continuation
            )
            send(
                .exportHTML(
                    ExportHTMLPayload(
                        exportID: exportID,
                        renderID: renderID,
                        phase: .discovery
                    )
                )
            )
        }
    }

    func handleExportHTMLResult(_ payload: ExportHTMLResultPayload) {
        guard let pending = pendingHTMLExport,
              pending.exportID == payload.exportID,
              pending.renderID == payload.renderID
        else {
            return
        }

        switch payload.state {
        case let .resourcesNeeded(resources):
            send(
                .exportHTML(
                    ExportHTMLPayload(
                        exportID: payload.exportID,
                        renderID: payload.renderID,
                        phase: .finalization,
                        resourceOutcomes: resources.map { ExportResourceOutcome.omit($0) }
                    )
                )
            )
        case let .ready(html):
            pendingHTMLExport = nil
            pending.continuation.resume(
                returning: .ready(html: html, exportID: payload.exportID, renderID: payload.renderID)
            )
        case let .failed(reason):
            pendingHTMLExport = nil
            pending.continuation.resume(
                returning: .failed(reason: reason, exportID: payload.exportID, renderID: payload.renderID)
            )
        }
    }

    func failPendingHTMLExport(reason: String) {
        guard let pending = pendingHTMLExport else { return }
        pendingHTMLExport = nil
        pending.continuation.resume(
            returning: .failed(reason: reason, exportID: pending.exportID, renderID: pending.renderID)
        )
    }
}

struct PendingHTMLExport {
    let exportID: Int
    let renderID: Int
    let continuation: CheckedContinuation<PreviewHTMLExportResult, Never>
}
