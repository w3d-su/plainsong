import Foundation

/// Owns the debounced visible-range highlight requests of one `MarkdownEditorView`.
/// Restarting directly avoids the observed SwiftUI `.task(id:)` final-request drop.
///
/// A restart supersedes all older work at once: it cancels the previous debounce, drops a
/// request queued behind a parse, and cancels the executing request. The new debounce starts
/// in the caller's turn, as `.task(id:)` did, so the final highlight is not delayed by a
/// cancelled parse. Only the apply/parse phase is serialized: one runner starts a request
/// that finished its debounce only after the cancelled one returns, so at most one request
/// executes (and at most one off-main parse is in flight), with at most one queued behind it.
@MainActor
final class EditorHighlightScheduler: ObservableObject {
    /// Returns `false` when the wait was cancelled. Production uses the 20 ms editor debounce,
    /// whose `Task.sleep` returns as soon as a superseded debounce is cancelled.
    typealias Debounce = @Sendable () async -> Bool
    private let debounce: Debounce
    private var isActive = true
    private var waiting: Task<Void, Never>?
    private var pending: (@MainActor () async -> Void)?
    private var request: Task<Void, Never>?
    private var runner: Task<Void, Never>?

    init(debounce: @escaping Debounce = { await MarkdownEditorView.waitForHighlightDebounce() }) {
        self.debounce = debounce
    }

    /// Supersedes older work and schedules `apply(revision)` after the debounce. Ignored while
    /// the view is not visible, so a queued viewport report cannot start a parse after
    /// `cancel()`. Cancellation is cooperative: an off-main parse can still be returning.
    func restart(revision: Int, apply: @escaping @MainActor (Int) async -> Void) {
        guard isActive else { return }
        waiting?.cancel()
        pending = nil
        request?.cancel()
        let debounce = debounce
        waiting = Task { @MainActor [weak self] in
            guard await debounce(), !Task.isCancelled, let self else { return }
            enqueue {
                guard !Task.isCancelled else { return }
                await apply(revision)
            }
        }
    }

    /// Re-enables requests when the view appears again.
    func activate() {
        isActive = true
    }

    /// Disappearance drops the debounce and the queued request and cancels the executing one;
    /// later restarts are ignored until `activate()`.
    func cancel() {
        isActive = false
        waiting?.cancel()
        waiting = nil
        pending = nil
        request?.cancel()
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        pending = operation
        guard runner == nil else { return }
        runner = Task { @MainActor in
            while let operation = pending {
                pending = nil
                let next = Task { @MainActor in await operation() }
                request = next
                await next.value
                request = nil
            }
            runner = nil
        }
    }
}
