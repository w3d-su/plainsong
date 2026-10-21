import Foundation
import MarkdownCore

@MainActor
protocol IOSAuthoringFindScheduling: AnyObject {
    func schedule(
        operation: @escaping @Sendable () -> EditorFindSession,
        deliver: @escaping @MainActor (EditorFindSession) -> Void
    )
    func cancel()
}

/// One running synchronous scan and one latest pending scan. Cancellation fences
/// delivery, but the running worker must drain before another scan starts.
@MainActor
final class IOSAuthoringDetachedFindScheduler: IOSAuthoringFindScheduling {
    private struct Work {
        let generation: UInt64
        let operation: @Sendable () -> EditorFindSession
        let deliver: @MainActor (EditorFindSession) -> Void
    }

    private var generation: UInt64 = 0
    private var pending: Work?
    private var worker: Task<EditorFindSession, Never>?
    private var runner: Task<Void, Never>?

    func schedule(
        operation: @escaping @Sendable () -> EditorFindSession,
        deliver: @escaping @MainActor (EditorFindSession) -> Void
    ) {
        generation &+= 1
        pending = Work(generation: generation, operation: operation, deliver: deliver)
        worker?.cancel()
        guard runner == nil else { return }
        runner = Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    func cancel() {
        generation &+= 1
        pending = nil
        worker?.cancel()
    }

    private func drain() async {
        while let work = pending {
            pending = nil
            let scan = Task.detached(priority: .userInitiated, operation: work.operation)
            worker = scan
            let session = await scan.value
            worker = nil
            if generation == work.generation {
                work.deliver(session)
            }
        }
        runner = nil
    }
}
