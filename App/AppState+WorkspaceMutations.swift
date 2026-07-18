import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func renameWorkspaceItem(
        at source: WorkspaceFileSystemLocation,
        to newName: String,
        expecting expectation: WorkspaceItemMutationExpectation,
        sourceParentExpectation: WorkspaceItemMutationExpectation
    ) throws {
        let destination = try workspaceRenameDestination(source: source, newName: newName)
        guard destination != source else { return }
        let plan = try prepareWorkspaceRelocationPlan(
            source: source,
            destination: destination,
            expectation: expectation
        )
        try beginWorkspaceNamespaceMutation(plan.records)
        defer {
            endWorkspaceNamespaceMutation(plan.records)
            resumeWorkspaceRelocationWork(plan.records)
            drainWorkspaceMutationRefreshIfNeeded()
        }
        let recoveryIntent = try prepareWorkspaceRelocationRecoveryIntent(
            plan: plan,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: sourceParentExpectation
        )

        let outcome = fileOperations.rename(
            source,
            to: newName,
            expecting: expectation,
            sourceParentExpectation: sourceParentExpectation,
            preparingCommit: { relocation in
                try self.prepareWorkspaceRelocationCommit(
                    plan: plan,
                    relocation: relocation
                )
            }
        )
        try finishWorkspaceRelocation(
            outcome,
            plan: plan,
            recoveryIntent: recoveryIntent
        )
    }

    func moveWorkspaceItem(
        at source: WorkspaceFileSystemLocation,
        toDirectoryRelativePath directoryRelativePath: String,
        expecting expectation: WorkspaceItemMutationExpectation,
        sourceParentExpectation: WorkspaceItemMutationExpectation,
        destinationParentExpectation: WorkspaceItemMutationExpectation
    ) throws {
        let destination = try workspaceMoveDestination(
            source: source,
            directoryRelativePath: directoryRelativePath
        )
        guard destination != source else { return }
        let plan = try prepareWorkspaceRelocationPlan(
            source: source,
            destination: destination,
            expectation: expectation
        )
        try beginWorkspaceNamespaceMutation(plan.records)
        defer {
            endWorkspaceNamespaceMutation(plan.records)
            resumeWorkspaceRelocationWork(plan.records)
            drainWorkspaceMutationRefreshIfNeeded()
        }
        let recoveryIntent = try prepareWorkspaceRelocationRecoveryIntent(
            plan: plan,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: destinationParentExpectation
        )

        let outcome = fileOperations.move(
            source,
            to: destination,
            expecting: expectation,
            sourceParentExpectation: sourceParentExpectation,
            destinationParentExpectation: destinationParentExpectation,
            preparingCommit: { relocation in
                try self.prepareWorkspaceRelocationCommit(
                    plan: plan,
                    relocation: relocation
                )
            }
        )
        try finishWorkspaceRelocation(
            outcome,
            plan: plan,
            recoveryIntent: recoveryIntent
        )
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func trashWorkspaceItem(
        at source: WorkspaceFileSystemLocation,
        expecting expectation: WorkspaceItemMutationExpectation,
        sourceParentExpectation: WorkspaceItemMutationExpectation
    ) async throws {
        let records = try prepareWorkspaceTrashRecords(
            source: source,
            expectation: expectation
        )
        if let dirtyRecord = records.first(where: { $0.session.isDirty }) {
            throw WorkspaceMutationError.unsavedChanges(dirtyRecord.oldURL)
        }
        let stagingPlan = try fileOperations.makeTrashStagingPlan(
            rootAuthority: source.rootAuthority
        )
        try beginWorkspaceNamespaceMutation(records.map(\.session))
        defer {
            endWorkspaceNamespaceMutation(records.map(\.session))
            resumeWorkspaceTrashWork(records)
            drainWorkspaceMutationRefreshIfNeeded()
        }
        installWorkspaceMutationTextRecovery(for: records, reason: .trash)
        do {
            try persistWorkspaceMutationTextRecovery(for: records.map(\.session))
        } catch {
            finishWorkspaceMutationTextRecoveryAfterNotTrashed(records)
            throw error
        }
        let initialRecoveryIntent = WorkspaceTrashRecoveryContext(
            id: UUID(),
            source: source,
            expectation: expectation,
            sourceParentExpectation: sourceParentExpectation,
            reason: .namespaceChanged,
            recoveryLocation: stagingPlan.stagingLocation,
            reportedTrashURL: nil,
            reportedTrashBookmarkData: nil,
            reportedTrashAuthorityLocation: nil,
            cleanupState: .removalIndeterminate(stagingPlan.stagingLocation),
            actualStagedExpectation: nil,
            actualStagedEntryRecoveryLocation: nil,
            records: records,
            remainingSessionIDs: Set(records.map { ObjectIdentifier($0.session) })
        )
        let recoveryIntent: WorkspaceTrashRecoveryContext
        do {
            recoveryIntent = try prepareWorkspaceTrashRecoveryIntent(
                initialRecoveryIntent
            )
        } catch {
            finishWorkspaceMutationTextRecoveryAfterNotTrashed(records)
            throw error
        }

        let outcome = await fileOperations.trash(
            source,
            expecting: expectation,
            sourceParentExpectation: sourceParentExpectation,
            stagingPlan: stagingPlan
        )
        switch outcome {
        case let .notTrashed(item):
            recordWorkspaceTrashCleanupState(item.stagingCleanupState)
            guard item.source == source,
                  item.expectation == expectation
            else {
                installWorkspaceTrashRecovery(
                    recoveryIntent,
                    reason: .namespaceChanged,
                    recoveryLocation: nil,
                    reportedTrashURL: nil,
                    cleanupState: item.stagingCleanupState,
                    actualStagedExpectation: nil
                )
                throw WorkspaceMutationError.indeterminateOperation(
                    source.fileURL,
                    .namespaceChanged
                )
            }
            do {
                try ensureWorkspaceMutationRecoveryTextIsDurable(
                    .trash(recoveryIntent)
                )
            } catch {
                do {
                    try persistWorkspaceMutationRecoveryIntent(.trash(recoveryIntent))
                } catch {
                    present(error, title: "Could Not Preserve Workspace Recovery")
                }
                workspaceMutationOperationRecoveryIDsWithUnpromotedText.insert(
                    recoveryIntent.id
                )
                var cleanupIntent = recoveryIntent
                cleanupIntent.reason = item.reason
                cleanupIntent.recoveryLocation = nil
                cleanupIntent.cleanupState = item.stagingCleanupState
                installWorkspaceTrashCleanupRecovery(cleanupIntent)
                throw WorkspaceMutationError.indeterminateOperation(
                    source.fileURL,
                    item.reason
                )
            }
            let verifiedPendingRecovery: WorkspaceTrashRecoveryContext
            do {
                verifiedPendingRecovery = try resolveWorkspaceTrashAuthorities(
                    recoveryIntent
                )
                guard workspaceTrashSourceIsSoleExpectedLocation(
                    verifiedPendingRecovery
                ) else {
                    throw WorkspaceMutationError.indeterminateOperation(
                        source.fileURL,
                        item.reason
                    )
                }
            } catch {
                var cleanupIntent = recoveryIntent
                cleanupIntent.reason = item.reason
                cleanupIntent.recoveryLocation = nil
                cleanupIntent.cleanupState = item.stagingCleanupState
                installWorkspaceTrashRecovery(
                    cleanupIntent,
                    reason: item.reason,
                    recoveryLocation: nil,
                    reportedTrashURL: nil,
                    cleanupState: item.stagingCleanupState,
                    actualStagedExpectation: nil
                )
                throw error
            }
            finishWorkspaceMutationTextRecoveryAfterNotTrashed(records)
            markWorkspaceMutationRecoveryBundledTextCommitted(id: recoveryIntent.id)
            do {
                try removePersistedWorkspaceMutationRecovery(id: recoveryIntent.id)
                clearInstalledWorkspaceMutationRecovery(
                    id: recoveryIntent.id,
                    knownRecovery: .trash(verifiedPendingRecovery)
                )
            } catch {
                var cleanupIntent = verifiedPendingRecovery
                cleanupIntent.reason = item.reason
                cleanupIntent.recoveryLocation = nil
                cleanupIntent.cleanupState = item.stagingCleanupState
                installWorkspaceTrashCleanupRecovery(cleanupIntent)
                throw WorkspaceMutationError.indeterminateOperation(
                    source.fileURL,
                    item.reason
                )
            }
            throw WorkspaceMutationError.operationFailed(item.reason, source.fileURL)
        case let .trashed(item):
            guard item.source == source,
                  item.expectation == expectation
            else {
                installWorkspaceTrashRecovery(
                    recoveryIntent,
                    reason: .namespaceChanged,
                    recoveryLocation: nil,
                    reportedTrashURL: item.trashURL,
                    cleanupState: item.stagingCleanupState,
                    actualStagedExpectation: nil
                )
                throw WorkspaceMutationError.indeterminateOperation(
                    source.fileURL,
                    .namespaceChanged
                )
            }
            recordWorkspaceTrashCleanupState(item.stagingCleanupState)
            do {
                try ensureWorkspaceMutationRecoveryTextIsDurable(
                    .trash(recoveryIntent)
                )
            } catch {
                do {
                    try persistWorkspaceMutationRecoveryIntent(.trash(recoveryIntent))
                } catch {
                    present(error, title: "Could Not Preserve Workspace Recovery")
                }
                workspaceMutationOperationRecoveryIDsWithUnpromotedText.insert(
                    recoveryIntent.id
                )
                installWorkspaceTrashRecovery(
                    recoveryIntent,
                    reason: .namespaceChanged,
                    recoveryLocation: nil,
                    reportedTrashURL: item.trashURL,
                    cleanupState: item.stagingCleanupState,
                    actualStagedExpectation: nil
                )
                throw WorkspaceMutationError.indeterminateOperation(
                    item.trashURL,
                    .namespaceChanged
                )
            }
            let committedRecovery: WorkspaceTrashRecoveryContext
            do {
                var terminalRecovery = recoveryIntent
                terminalRecovery.recoveryLocation = nil
                terminalRecovery.cleanupState = item.stagingCleanupState
                committedRecovery = try prepareWorkspaceTrashCommittedRecovery(
                    terminalRecovery,
                    reportedTrashURL: item.trashURL
                )
            } catch {
                installWorkspaceTrashRecovery(
                    recoveryIntent,
                    reason: .namespaceChanged,
                    recoveryLocation: nil,
                    reportedTrashURL: item.trashURL,
                    cleanupState: item.stagingCleanupState,
                    actualStagedExpectation: nil
                )
                throw WorkspaceMutationError.indeterminateOperation(
                    item.trashURL,
                    .namespaceChanged
                )
            }
            finishWorkspaceTrash(records)
            let verifiedCommittedRecovery: WorkspaceTrashRecoveryContext
            do {
                verifiedCommittedRecovery = try resolveWorkspaceTrashAuthorities(
                    committedRecovery
                )
                guard provenReportedTrashLocation(verifiedCommittedRecovery) != nil else {
                    throw WorkspaceMutationError.indeterminateOperation(
                        item.trashURL,
                        .namespaceChanged
                    )
                }
            } catch {
                var cleanupIntent = committedRecovery
                cleanupIntent.reason = .namespaceChanged
                cleanupIntent.recoveryLocation = nil
                cleanupIntent.cleanupState = item.stagingCleanupState
                installWorkspaceTrashCleanupRecovery(cleanupIntent)
                throw error
            }
            markWorkspaceMutationRecoveryBundledTextCommitted(id: recoveryIntent.id)
            do {
                try removePersistedWorkspaceMutationRecovery(id: recoveryIntent.id)
                clearInstalledWorkspaceMutationRecovery(
                    id: recoveryIntent.id,
                    knownRecovery: .trash(verifiedCommittedRecovery)
                )
            } catch {
                var cleanupIntent = verifiedCommittedRecovery
                cleanupIntent.reason = .namespaceChanged
                cleanupIntent.recoveryLocation = nil
                cleanupIntent.cleanupState = item.stagingCleanupState
                installWorkspaceTrashCleanupRecovery(cleanupIntent)
                throw WorkspaceMutationError.indeterminateOperation(
                    item.trashURL,
                    .namespaceChanged
                )
            }
        case let .trashStateIndeterminate(indeterminate):
            recordWorkspaceTrashCleanupState(indeterminate.stagingCleanupState)
            installWorkspaceTrashRecovery(
                recoveryIntent,
                reason: indeterminate.reason,
                recoveryLocation: indeterminate.recoveryLocation,
                reportedTrashURL: indeterminate.reportedTrashURL,
                cleanupState: indeterminate.stagingCleanupState,
                actualStagedExpectation: indeterminate.actualStagedExpectation
            )
            throw WorkspaceMutationError.indeterminateOperation(
                indeterminate.recoveryLocation?.fileURL ?? source.fileURL,
                indeterminate.reason
            )
        }
    }
}
