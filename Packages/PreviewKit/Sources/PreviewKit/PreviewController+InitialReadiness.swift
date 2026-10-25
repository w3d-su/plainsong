import Foundation

/// A silent first page gets one retry. Ready, disposal and process termination
/// permanently retire this deadline; later recovery uses its own bounded policy.
@MainActor
struct PreviewInitialReadiness {
    typealias Cancellation = @MainActor () -> Void
    typealias Scheduler = @MainActor (UInt64, @escaping @MainActor () -> Void) -> Cancellation

    static let timeoutNanoseconds: UInt64 = 2_500_000_000
    #if os(iOS)
        static let retriesSilentInitialLoadByDefault = true
    #else
        static let retriesSilentInitialLoadByDefault = false
    #endif
    var epoch: UUID?
    var cancellation: Cancellation?
    var isFinished = false
    var requiresRetryProbe = false

    mutating func finish() {
        isFinished = true
        epoch = nil
        let cancel = cancellation
        cancellation = nil
        cancel?()
    }

    static func schedule(after delay: UInt64, fire: @escaping @MainActor () -> Void) -> Cancellation {
        let task = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            fire()
        }
        return { task.cancel() }
    }
}

extension PreviewController {
    func startInitialReadinessWatchdog() {
        guard retriesSilentInitialLoad, !initialReadiness.isFinished,
              initialReadiness.epoch == nil else { return }
        let epoch = UUID()
        initialReadiness.epoch = epoch
        let cancel = initialReadinessScheduler(PreviewInitialReadiness.timeoutNanoseconds) { [weak self] in
            self?.initialReadinessTimedOut(epoch: epoch)
        }
        // A deterministic scheduler may fire synchronously while it is installed.
        if initialReadiness.epoch == epoch {
            initialReadiness.cancellation = cancel
        } else {
            cancel()
        }
    }

    func finishInitialReadinessWatchdog() {
        initialReadiness.finish()
    }

    private func initialReadinessTimedOut(epoch: UUID) {
        guard initialReadiness.epoch == epoch else { return }
        // Spend the retry before loading: neither a late fire nor synchronous
        // ready/termination callbacks can re-arm or recursively reload it.
        finishInitialReadinessWatchdog()
        guard !isInvalidated, !isReady, !webContentProcessTerminated,
              renderDispatch.inFlightRenderID == nil, renderDispatch.lastSent == nil,
              pendingHTMLExport == nil else { return }

        // No render reached this silent initial page. Keep the queued export's
        // exact ID/continuation, latest source, asset context and scroll barrier.
        initialReadiness.requiresRetryProbe = true
        resetRenderDispatch(keepingPending: true)
        loadPreviewPage(stoppingCurrentLoad: true)
    }
}
