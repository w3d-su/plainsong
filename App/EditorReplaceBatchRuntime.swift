import Foundation
import MarkdownCore

/// Cancellation belongs to preparation only. The synchronous native commit never reads it.
final class EditorReplaceBatchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var explicitCancel = false

    func cancel(explicit: Bool = false) {
        lock.lock()
        explicitCancel = explicitCancel || explicit
        cancelled = true
        lock.unlock()
    }

    var wasExplicitlyCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return explicitCancel
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Replace All's in-flight state as the bar presents it (`docs/editor-replace-gates.md` §5.3).
enum EditorReplaceActivity: Equatable {
    case idle
    /// Cancellable off-main preparation; `Preparing n / total`.
    case preparing(completed: Int, total: Int)
    /// The non-cancellable synchronous commit; `Applying…`, Cancel disabled.
    case applying
}

@MainActor
final class EditorReplaceBatchRuntime {
    private(set) var actionID: UInt64 = 0
    private(set) var replacementGeneration: UInt64 = 0
    private(set) var replacement = ""
    private(set) var cancellation: EditorReplaceBatchCancellation?
    var preparationTask: Task<Result<EditorReplacePreparedBatch, EditorReplaceBatchPreparationFailure>, Never>?
    var preparationActionID: UInt64?
    var onChunkForTesting: (@Sendable (EditorReplacePreparationChunk) -> Void)?
    var onProgressForTesting: ((EditorReplacePreparationProgress) -> Void)?
    var willCommitForTesting: (() -> Void)?
    var isPreparing = false {
        didSet { if isPreparing != oldValue { onPresentationChange?() } }
    }

    /// The synchronous commit turn: nothing can render it, but the bar and tests read it.
    var isApplying = false {
        didSet { if isApplying != oldValue { onPresentationChange?() } }
    }

    var progress: [EditorReplacePreparationProgress] = [] {
        didSet { onPresentationChange?() }
    }

    /// Retained match total of the plan being prepared, for `Preparing 0 / total`.
    private(set) var preparationTotal = 0
    /// App publishes the bar from here; never called per editor keystroke.
    var onPresentationChange: (() -> Void)?
    var lastPreparationRanOffMain = false
    var preparationMilliseconds = 0.0
    var commitMilliseconds = 0.0
    var lastResult: EditorReplaceBatchCommandResult?

    func cancel() {
        cancellation?.cancel(explicit: true)
        supersede()
    }

    func setReplacement(_ value: String) -> Bool {
        guard !ExactSourceText.matches(replacement, value) else { return false }
        replacement = value
        precondition(replacementGeneration < .max)
        replacementGeneration += 1
        cancellation?.cancel()
        return true
    }

    func begin(total: Int = 0) -> EditorReplaceBatchCancellation {
        supersede()
        let token = EditorReplaceBatchCancellation()
        cancellation = token
        preparationTotal = total
        progress = []
        isPreparing = true
        return token
    }

    /// Stops a plan that has not reached its synchronous commit. Commit has already cleared
    /// `isPreparing`, so this can never interrupt an admitted native write.
    func supersedeIfPreparing() {
        guard isPreparing else { return }
        supersede()
    }

    /// What the replacement row shows while an action is in flight.
    var activity: EditorReplaceActivity {
        if isApplying {
            return .applying
        }
        guard isPreparing else { return .idle }
        let latest = progress.last
        return .preparing(
            completed: latest?.completedMatchCount ?? 0,
            total: latest?.totalMatchCount ?? preparationTotal
        )
    }

    func supersede() {
        precondition(actionID < .max)
        actionID += 1
        cancellation?.cancel()
        isPreparing = false
    }

    func finish(action: UInt64, result: EditorReplaceBatchCommandResult) {
        if preparationActionID == action {
            preparationTask = nil
            preparationActionID = nil
            isPreparing = false
            cancellation = nil
            lastResult = result
        }
        guard actionID == action else { return }
        isPreparing = false
        cancellation = nil
        lastResult = result
    }
}
