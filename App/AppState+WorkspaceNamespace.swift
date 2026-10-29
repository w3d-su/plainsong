import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func beginWorkspaceNamespaceMutation(
        _ records: [WorkspaceSessionRelocationRecord]
    ) throws {
        try beginWorkspaceNamespaceMutation(records.map(\.session))
    }

    func beginWorkspaceNamespaceMutation(
        _ sessions: [DocumentSession],
        allowingExistingRecovery: Bool = false
    ) throws {
        try validateWorkspaceMutationRecoveryStoresLoaded()
        if !allowingExistingRecovery,
           let recovery = nextWorkspaceMutationRecovery()
        {
            throw WorkspaceMutationError.indeterminateSession(recovery.sourceURL)
        }
        guard workspaceMutationNamespaceDepth == 0 else {
            throw WorkspaceMutationError.operationAlreadyInProgress
        }
        guard workspaceImageAssetInsertionCount == 0 else {
            throw WorkspaceMutationError.imageInsertionInProgress
        }
        workspaceMutationNamespaceDepth = 1
        workspaceMutationRefreshPending = true
        workspaceMutationExternalRefreshPending = false
        workspaceMutationRefreshRootAuthority = workspaceSearchRootAuthority
        _ = advanceWorkspaceGeneration()
        workspaceReloadTask?.cancel()
        workspaceReloadTask = nil
        completionWorkspaceTask?.cancel()
        completionWorkspaceTask = nil
        var seen: Set<ObjectIdentifier> = []
        for session in sessions where seen.insert(ObjectIdentifier(session)).inserted {
            let sessionIdentity = ObjectIdentifier(session)
            workspaceMutationWriteFences.insert(sessionIdentity)
            cancelAutosave(for: session)
            externalDiskInspectionTasks.removeValue(forKey: sessionIdentity)?.task.cancel()
            supersedeExternalResolutionRead(for: session)
            _ = advanceSessionLifecycle(for: session)
            _ = advanceExternalDiskEventGeneration(for: session)
        }
    }

    func endWorkspaceNamespaceMutation(_ records: [WorkspaceSessionRelocationRecord]) {
        endWorkspaceNamespaceMutation(records.map(\.session))
    }

    func endWorkspaceNamespaceMutation(_ sessions: [DocumentSession]) {
        _ = sessions
        precondition(workspaceMutationNamespaceDepth == 1)
        workspaceMutationWriteFences.removeAll()
        workspaceMutationNamespaceDepth = 0
    }

    func drainWorkspaceMutationRefreshIfNeeded() {
        guard workspaceMutationRefreshPending else { return }
        workspaceMutationRefreshPending = false
        let inspectManagedSessions = workspaceMutationExternalRefreshPending
        workspaceMutationExternalRefreshPending = false
        let retainedRootAuthority = workspaceMutationRefreshRootAuthority
        workspaceMutationRefreshRootAuthority = nil
        if let retainedRootAuthority {
            refreshWorkspaceAfterNamespaceMutation(
                using: retainedRootAuthority,
                inspectManagedSessions: inspectManagedSessions
            )
        } else {
            refreshWorkspaceAfterFileSystemChange()
        }
    }

}
