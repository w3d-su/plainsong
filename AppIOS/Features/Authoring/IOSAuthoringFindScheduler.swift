import Foundation
import MarkdownCore

@MainActor
protocol IOSAuthoringFindScheduling: AnyObject {
    func schedule(
        operation: @escaping @Sendable () -> EditorFindSession,
        deliver: @escaping @MainActor (EditorFindSession) -> Void
    )
}

/// One latest search. The caller returns before `EditorFindSession.search` runs.
@MainActor
final class IOSAuthoringDetachedFindScheduler: IOSAuthoringFindScheduling {
    private var task: Task<Void, Never>?

    func schedule(
        operation: @escaping @Sendable () -> EditorFindSession,
        deliver: @escaping @MainActor (EditorFindSession) -> Void
    ) {
        task?.cancel()
        task = Task { @MainActor in
            let session = await Task.detached(priority: .userInitiated, operation: operation).value
            guard !Task.isCancelled else { return }
            deliver(session)
        }
    }
}
