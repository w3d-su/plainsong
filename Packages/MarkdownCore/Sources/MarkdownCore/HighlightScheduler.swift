import Foundation

/// One debounced highlight runner. The next debounce starts immediately; at most one
/// parse executes, with at most one newer request waiting behind it.
@MainActor
public final class HighlightScheduler {
    public typealias Debounce = @Sendable () async -> Bool

    private let debounce: Debounce
    private var isActive = true
    public private(set) var epoch: UInt64 = 0
    private var waiting: Task<Void, Never>?
    private var pending: (@MainActor () async -> Void)?
    private var request: Task<Void, Never>?
    private var runner: Task<Void, Never>?

    public init(debounce: @escaping Debounce) {
        self.debounce = debounce
    }

    public static func productionDebounce() async -> Bool {
        do {
            try await Task.sleep(nanoseconds: 20_000_000)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    public func restart(apply: @escaping @MainActor (UInt64) async -> Void) {
        guard isActive else { return }
        waiting?.cancel()
        pending = nil
        request?.cancel()
        let capturedEpoch = epoch
        let debounce = debounce
        waiting = Task { @MainActor [weak self] in
            let accepted = await debounce()
            guard accepted, !Task.isCancelled, let self, isActive, epoch == capturedEpoch else {
                return
            }
            enqueue {
                guard !Task.isCancelled, self.epoch == capturedEpoch else { return }
                await apply(capturedEpoch)
            }
        }
    }

    public func activate() {
        isActive = true
    }

    /// Hide or unmount. Queued work is dropped and a late result cannot match `epoch`.
    public func cancel() {
        isActive = false
        bumpEpoch()
        waiting?.cancel()
        waiting = nil
        pending = nil
        request?.cancel()
    }

    /// Reconciliation floor. Stays active so the caller can schedule the replacement parse.
    public func invalidateInFlight() {
        bumpEpoch()
        waiting?.cancel()
        waiting = nil
        pending = nil
        request?.cancel()
    }

    private func bumpEpoch() {
        epoch &+= 1
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        pending = operation
        guard runner == nil else { return }
        runner = Task { @MainActor in
            while let operation = self.pending {
                self.pending = nil
                let next = Task { @MainActor in
                    await operation()
                }
                self.request = next
                await next.value
                self.request = nil
            }
            self.runner = nil
        }
    }
}
