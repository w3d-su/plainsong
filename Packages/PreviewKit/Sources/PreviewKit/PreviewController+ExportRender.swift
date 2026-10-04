import Foundation
import MarkdownCore

/// The outcome of one dedicated offscreen export render (`docs/export-gates.md` D1).
public enum PreviewExportRenderResult: Equatable, Sendable {
    /// The exact submitted render posted `renderComplete`. This is necessary but not
    /// sufficient: an MDX error also posts it while keeping stale DOM, so the caller must
    /// still pass `renderID` to `exportHTML(matchingRenderID:)`, which applies the D2 barrier.
    case completed(renderID: Int)
    /// The wait ended without that exact `renderComplete`. `renderID` is `-1` when nothing
    /// was submitted.
    case failed(reason: String, renderID: Int)
}

extension PreviewController {
    /// D1: submits one operation-snapshot render on a dedicated offscreen export controller
    /// and waits for that exact render's `renderComplete`.
    ///
    /// Call only on a controller the export operation owns, after `setAllowsRemoteImages(false)`
    /// and `setTheme(_:)`; never on the visible pane's controller. A render queued before the
    /// bridge is ready is sent when it becomes ready. Cancellation, the export timeout,
    /// `invalidate()`, WebContent termination, and a newer render each resolve the wait
    /// exactly once as `.failed`. The owner still invalidates the controller when the
    /// operation ends.
    public func renderForExport(_ change: DocumentTextChange) async -> PreviewExportRenderResult {
        guard !Task.isCancelled else {
            return .failed(reason: "cancelled", renderID: -1)
        }
        guard !isInvalidated else {
            return .failed(reason: "invalidated", renderID: -1)
        }
        // Submitting fails any older pending export render as superseded.
        let renderID = submitRender(change)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .failed(reason: "cancelled", renderID: renderID))
                    return
                }
                pendingExportRender = PendingExportRender(renderID: renderID, continuation: continuation)
                let timeout = exportTimeoutNanoseconds
                pendingExportRender?.timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: timeout) } catch { return }
                    self?.failPendingExportRender(reason: "timeout", matchingRenderID: renderID)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.failPendingExportRender(reason: "cancelled", matchingRenderID: renderID)
            }
        }
    }

    /// Resolves the pending export render only for its exact render ID.
    func completePendingExportRender(_ renderID: Int) {
        guard pendingExportRender?.renderID == renderID else { return }
        finishPendingExportRender(.completed(renderID: renderID))
    }

    func failPendingExportRender(reason: String, matchingRenderID: Int? = nil) {
        guard let pending = pendingExportRender,
              matchingRenderID == nil || matchingRenderID == pending.renderID
        else { return }
        finishPendingExportRender(.failed(reason: reason, renderID: pending.renderID))
    }

    /// One lifecycle event (a newer render, invalidation, or WebContent termination) resolves
    /// both the export-render wait and any pending HTML export.
    func failPendingExportWork(reason: String) {
        failPendingExportRender(reason: reason)
        failPendingHTMLExport(reason: reason)
    }

    private func finishPendingExportRender(_ result: PreviewExportRenderResult) {
        guard let pending = pendingExportRender else { return }
        pendingExportRender = nil
        pending.timeoutTask?.cancel()
        pending.continuation.resume(returning: result)
    }
}

struct PendingExportRender {
    let renderID: Int
    let continuation: CheckedContinuation<PreviewExportRenderResult, Never>
    var timeoutTask: Task<Void, Never>?
}
