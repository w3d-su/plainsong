import Foundation

/// WebContent recovery for the live preview (`docs/decisions/2026-10-22-preview-webview-lifecycle.md`).
///
/// A terminated WebContent process (a crash, or memory pressure reclaiming a hidden pane)
/// left a blank web view that never became ready again, so the preview stayed empty until
/// relaunch. A live controller now reloads the bundled page and re-submits the newest render
/// under a new render ID. Export controllers do not recover: their operation fails typed.
extension PreviewController {
    /// Terminations in a row without a completed render after which recovery stops, so a
    /// document that crashes WebKit cannot reload forever. A later completed render re-arms it.
    static let maximumConsecutiveRecoveries = 3

    func recoverFromWebContentTermination(resubmitting request: PreviewRenderRequest?) {
        guard recoversFromWebContentTermination, !isInvalidated else { return }
        consecutiveWebContentTerminations += 1
        guard consecutiveWebContentTerminations <= Self.maximumConsecutiveRecoveries else { return }
        if let request {
            resubmitRender(request)
        }
        reloadPreviewPageAfterTermination()
    }

    /// A page finished rendering, so the current content does not crash WebKit.
    func noteRenderCompletedForRecovery() {
        consecutiveWebContentTerminations = 0
    }

    /// After recovery gave up, each new render gets one more page load: the edit may have
    /// removed what crashed WebKit. Reloads stay bounded to one per new render.
    func retryExhaustedRecoveryForNewRender() {
        guard recoversFromWebContentTermination, webContentProcessTerminated, !isInvalidated,
              consecutiveWebContentTerminations > Self.maximumConsecutiveRecoveries
        else { return }
        consecutiveWebContentTerminations = Self.maximumConsecutiveRecoveries
        reloadPreviewPageAfterTermination()
    }
}
