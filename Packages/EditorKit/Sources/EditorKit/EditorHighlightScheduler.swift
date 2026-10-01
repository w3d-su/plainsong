import Foundation

/// Owns one executing highlight request and one replaceable pending request.
/// Restarting directly avoids the observed SwiftUI `.task(id:)` final-request drop.
@MainActor
final class EditorHighlightScheduler: ObservableObject {
    typealias Debounce = @Sendable () async -> Bool
    private let debounce: Debounce
    private var pending: (@MainActor () async -> Void)?
    private var request: Task<Void, Never>?
    private var runner: Task<Void, Never>?

    init(debounce: @escaping Debounce = { await MarkdownEditorView.waitForHighlightDebounce() }) {
        self.debounce = debounce
    }

    /// Cancel the executing request and replace pending work with the latest revision.
    /// Cancellation is cooperative: an off-main parse can still be returning. The single
    /// runner waits for it before starting the pending request, bounding task ownership
    /// even when the debounce or parser does not return immediately on cancellation.
    func restart(revision: Int, apply: @escaping @MainActor (Int) async -> Void) {
        let debounce = debounce
        pending = {
            guard await debounce(), !Task.isCancelled else { return }
            await apply(revision)
        }
        request?.cancel()
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

    /// Disappearance drops pending work and cancels the executing request. A subsequent
    /// appearance may enqueue a new request while the cancelled one finishes returning.
    func cancel() {
        pending = nil
        request?.cancel()
    }
}
