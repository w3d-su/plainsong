import Foundation
import MarkdownCore

/// Fence token for an in-flight match computation.
private struct EditorFindMatchFence: Equatable {
    let documentIdentity: EditorDocumentIdentity?
    let sourceRevision: UInt64
    let queryGeneration: UInt64
}

/// Long-lived task owner. Tasks capture the controller weakly, just as before extraction.
@MainActor
final class EditorFindMatchWorker {
    private var matchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    deinit {
        matchTask?.cancel()
        debounceTask?.cancel()
    }

    /// Returns whether either admission or match work was superseded.
    func cancel() -> Bool {
        let hadWork = debounceTask != nil || matchTask != nil
        debounceTask?.cancel()
        debounceTask = nil
        matchTask?.cancel()
        matchTask = nil
        return hadWork
    }

    func schedule<Owner: AnyObject, Work>(
        owner: Owner, work: Work, debounce: UInt64, run: @escaping @MainActor (Owner, Work) -> Void
    ) {
        debounceTask = Task { @MainActor [weak owner] in
            if debounce > 0 {
                try? await Task.sleep(nanoseconds: debounce)
            }
            guard !Task.isCancelled, let owner else { return }
            run(owner, work)
        }
    }

    struct Request {
        let binding: EditorFindDocumentBinding
        let generation: UInt64
        let hold: EditorFindMatchHold?
        let forceMain: Bool
    }

    func start<Owner: AnyObject, Output: Sendable>(
        owner: Owner,
        request: Request,
        compute: @escaping @Sendable () -> Output,
        current: @escaping @MainActor (Owner) -> (EditorFindDocumentBinding, UInt64),
        apply: @escaping @MainActor (Owner, Output, Bool, Bool) -> Void
    ) {
        startMatchWork(owner: owner, request: request, compute: compute, current: current, apply: apply)
    }

    private func startMatchWork<Owner: AnyObject, Output: Sendable>(
        owner: Owner,
        request: Request,
        compute: @escaping @Sendable () -> Output,
        current: @escaping @MainActor (Owner) -> (EditorFindDocumentBinding, UInt64),
        apply: @escaping @MainActor (Owner, Output, Bool, Bool) -> Void
    ) {
        let fence = Self.fence(request.binding, generation: request.generation)
        let hold = request.hold
        let forceMain = request.forceMain
        matchTask?.cancel()
        matchTask = Task { @MainActor [weak owner] in
            let result: (output: Output, ranOffMain: Bool)
            if forceMain {
                if let hold {
                    await hold.waitIfHeld()
                }
                // Negative control path: same computation on the main actor.
                result = (compute(), Self.currentlyOffMainThread())
            } else {
                result = await Task.detached(priority: .userInitiated) {
                    if let hold {
                        await hold.waitIfHeld()
                    }
                    return (compute(), Self.currentlyOffMainThread())
                }.value
            }

            // Cancellation still completes and fence-drops. Only owner lifetime ends apply.
            guard let owner else { return }
            let (binding, generation) = current(owner)
            apply(owner, result.output, result.ranOffMain, Self.fence(binding, generation: generation) == fence)
        }
    }

    private static func fence(_ binding: EditorFindDocumentBinding, generation: UInt64) -> EditorFindMatchFence {
        EditorFindMatchFence(
            documentIdentity: binding.identity,
            sourceRevision: binding.revision,
            queryGeneration: generation
        )
    }

    /// Synchronous, nonisolated probe: true when the calling thread is not the main thread.
    /// Uses `pthread_main_np` so it is valid from async/detached contexts (unlike
    /// `Thread.isMainThread` under Swift 6 async unavailability).
    private nonisolated static func currentlyOffMainThread() -> Bool {
        pthread_main_np() == 0
    }
}
