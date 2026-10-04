import Foundation
import MarkdownCore

/// Cancellation belongs to preparation only. The synchronous native commit never reads it.
final class EditorReplaceBatchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
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
    var isPreparing = false
    var progress: [EditorReplacePreparationProgress] = []
    var lastPreparationRanOffMain = false
    var preparationMilliseconds = 0.0
    var commitMilliseconds = 0.0
    var lastResult: EditorReplaceBatchCommandResult?

    func setReplacement(_ value: String) -> Bool {
        guard !ExactSourceText.matches(replacement, value) else { return false }
        replacement = value
        precondition(replacementGeneration < .max)
        replacementGeneration += 1
        cancellation?.cancel()
        return true
    }

    func begin() -> EditorReplaceBatchCancellation {
        supersede()
        let token = EditorReplaceBatchCancellation()
        cancellation = token
        isPreparing = true
        progress = []
        return token
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
