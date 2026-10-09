import EditorKitIOS
import Foundation
import WorkspaceCore
import WorkspaceKitIOS

/// Persists through `IOSWorkspaceAssetWriting`, then submits one captured `IOSAuthorizedEdit`.
/// Accepted source commits ownership. Every other terminal path rolls the staged leaf back once.
/// Undo stays the native text edit: a later undo does not delete the image.
@MainActor
final class IOSImageInsertionController: IOSImageInsertionControlling {
    private let writer: any IOSWorkspaceAssetWriting
    private let normalizer: IOSImagePayloadNormalizer
    private var operations: [UUID: IOSImageOperationState] = [:]

    init(
        writer: any IOSWorkspaceAssetWriting,
        normalizer: IOSImagePayloadNormalizer = IOSImagePayloadNormalizer()
    ) {
        self.writer = writer
        self.normalizer = normalizer
    }

    func captureContext(
        using editor: any IOSSourceEditorControlling,
        destination: IOSFileLocation,
        grant: IOSWorkspaceGrant
    ) -> IOSImageInsertionContext? {
        guard let snapshot = editor.captureSnapshot() else { return nil }
        guard IOSImageInsertionGuard.captureBlock(snapshot: snapshot, destination: destination, grant: grant) == nil
        else {
            return nil
        }
        let context = IOSImageInsertionContext(
            operationID: UUID(),
            editor: snapshot,
            destination: destination,
            grant: grant
        )
        operations[context.operationID] = IOSImageOperationState()
        return context
    }

    func cancel(operationID: UUID) {
        operations[operationID]?.cancelRequested = true
    }

    /// Load failed or the picker closed before persistence. No leaf exists to roll back.
    func discardUnstaged(operationID: UUID) {
        guard let state = operations[operationID], state.phase == .captured, state.staged == nil else { return }
        state.cancelRequested = true
        state.phase = .finished
    }

    func insert(
        bytes: Data,
        contentType: String,
        preferredFilename: String,
        context: IOSImageInsertionContext,
        using editor: any IOSSourceEditorControlling
    ) async -> IOSImageInsertionOutcome {
        guard let state = operations[context.operationID], state.phase == .captured else {
            return .cancelled
        }
        state.phase = .importing
        if state.cancelRequested {
            state.phase = .finished
            return .cancelled
        }
        guard let payload = await normalizedPayload(
            bytes: bytes,
            contentType: contentType,
            preferredFilename: preferredFilename,
            state: state
        ) else {
            return state.earlyOutcome ?? .failed(.unsupportedType)
        }
        if state.cancelRequested {
            state.phase = .finished
            return .cancelled
        }
        return await stageAndApply(payload, context: context, editor: editor, state: state)
    }

    private func normalizedPayload(
        bytes: Data,
        contentType: String,
        preferredFilename: String,
        state: IOSImageOperationState
    ) async -> IOSImageNormalizedPayload? {
        let normalizer = normalizer
        do {
            return try await Task.detached {
                try normalizer.normalize(bytes: bytes, contentType: contentType, preferredFilename: preferredFilename)
            }.value
        } catch let error as IOSImageNormalizationError {
            state.phase = .finished
            state.earlyOutcome = .failed(error.workspaceFailure)
            return nil
        } catch is CancellationError {
            state.phase = .finished
            state.earlyOutcome = .cancelled
            return nil
        } catch {
            state.phase = .finished
            state.earlyOutcome = .failed(.unsupportedType)
            return nil
        }
    }

    private func stageAndApply(
        _ payload: IOSImageNormalizedPayload,
        context: IOSImageInsertionContext,
        editor: any IOSSourceEditorControlling,
        state: IOSImageOperationState
    ) async -> IOSImageInsertionOutcome {
        let request = IOSImageAssetRequest(
            operationID: context.operationID,
            bytes: payload.bytes,
            contentType: payload.contentType,
            preferredFilename: payload.preferredFilename,
            destination: context.destination
        )
        let staged: IOSStagedImageAsset
        do {
            staged = try await writer.stage(request, grant: context.grant)
        } catch let failure as IOSAssetStageFailure {
            state.phase = .finished
            return stageOutcome(failure)
        } catch is CancellationError {
            state.phase = .finished
            return .cancelled
        } catch {
            state.phase = .finished
            return .failed(.coordinationFailed)
        }
        state.staged = staged
        if let cancelled = await cancelledRollback(staged, state: state) {
            return cancelled
        }
        do {
            try await writer.validate(staged)
        } catch let failure as IOSWorkspaceFailure {
            return await complete(staged, state: state, request: .rollback(failure: failure))
        } catch is CancellationError {
            return await complete(staged, state: state, request: .rollback(cancelled: true))
        } catch {
            return await complete(staged, state: state, request: .rollback(failure: .coordinationFailed))
        }
        return await applyValidated(staged, context: context, editor: editor, state: state)
    }

    private func applyValidated(
        _ staged: IOSStagedImageAsset,
        context: IOSImageInsertionContext,
        editor: any IOSSourceEditorControlling,
        state: IOSImageOperationState
    ) async -> IOSImageInsertionOutcome {
        if let cancelled = await cancelledRollback(staged, state: state) {
            return cancelled
        }
        guard let current = editor.captureSnapshot() else {
            return await complete(staged, state: state, request: .rollback(refusal: .unavailable))
        }
        if let refusal = IOSImageInsertionGuard.refusal(captured: context.editor, current: current) {
            return await complete(staged, state: state, request: .rollback(refusal: refusal))
        }
        if let failure = IOSImageInsertionGuard.destinationFailure(staged, context: context) {
            return await complete(staged, state: state, request: .rollback(failure: failure))
        }
        guard let edit = IOSImageInsertionGuard.authorizedEdit(context: context, relativePath: staged.relativePath)
        else {
            return await complete(staged, state: state, request: .rollback(failure: .invalidPath))
        }
        // Synchronous with the checks above. Do not retarget the latest caret after this await gap.
        switch editor.apply(edit) {
        case let .applied(revision):
            return await complete(
                staged,
                state: state,
                request: IOSImageTerminalRequest(applied: revision, action: .commit)
            )
        case let .refused(reason):
            return await complete(staged, state: state, request: .rollback(refusal: reason))
        }
    }

    private func cancelledRollback(
        _ staged: IOSStagedImageAsset,
        state: IOSImageOperationState
    ) async -> IOSImageInsertionOutcome? {
        guard state.cancelRequested else { return nil }
        return await complete(staged, state: state, request: .rollback(cancelled: true))
    }

    private func stageOutcome(_ failure: IOSAssetStageFailure) -> IOSImageInsertionOutcome {
        switch failure {
        case let .failed(reason):
            .failed(reason)
        case let .retained(receipt):
            .retained(receipt)
        }
    }

    private func complete(
        _ asset: IOSStagedImageAsset,
        state: IOSImageOperationState,
        request: IOSImageTerminalRequest
    ) async -> IOSImageInsertionOutcome {
        let terminal = await finish(request.action, asset: asset, state: state)
        return IOSImageTerminalMapping.outcome(terminal: terminal, asset: asset, request: request)
    }

    private func finish(
        _ action: IOSImageTerminalAction,
        asset: IOSStagedImageAsset,
        state: IOSImageOperationState
    ) async -> IOSImageAssetTerminal {
        if let existing = state.terminalTask {
            return await existing.value
        }
        let writer = writer
        let task = Task.detached {
            switch action {
            case .commit:
                let outcome = await writer.commit(asset)
                return IOSImageAssetTerminal.committed(outcome)
            case .rollback:
                let outcome = await writer.rollback(asset)
                return IOSImageAssetTerminal.rolledBack(outcome)
            }
        }
        state.terminalTask = task
        state.phase = .finished
        return await task.value
    }
}
