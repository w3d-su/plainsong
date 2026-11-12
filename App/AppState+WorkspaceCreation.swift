import EditorKit
import Foundation
import MarkdownCore
import WorkspaceKit

extension AppState {
    func performWorkspaceCreation(
        named name: String,
        kind: WorkspaceCreationKind,
        directoryID: WorkspaceFileNode.ID?
    ) {
        do {
            try validateWorkspaceMutationRecoveryStoresLoaded()
            guard workspaceMutationNamespaceDepth == 0 else {
                throw WorkspaceMutationError.operationAlreadyInProgress
            }
            guard workspaceImageAssetInsertionCount == 0 else {
                throw WorkspaceMutationError.imageInsertionInProgress
            }
            guard let tree = workspaceTree,
                  let rootAuthority = workspaceSearchRootAuthority,
                  workspaceInstalledCaptureGeneration == workspaceGeneration
            else {
                throw WorkspaceMutationError.unavailableWorkspaceDirectory
            }
            let directory = try workspaceCreationDirectory(
                directoryID: directoryID,
                tree: tree,
                rootAuthority: rootAuthority
            )
            let creationPlan = switch kind {
            case .file:
                try fileOperations.makeFileCreationPlan(
                    named: name,
                    inDirectoryRelativePath: directory.relativePath,
                    rootAuthority: rootAuthority,
                    expectingDirectory: directory.expectation
                )
            case .folder:
                try fileOperations.makeFolderCreationPlan(
                    named: name,
                    inDirectoryRelativePath: directory.relativePath,
                    rootAuthority: rootAuthority,
                    expectingDirectory: directory.expectation
                )
            }
            try validateWorkspaceMutationDestinationOwnership(creationPlan.destination)

            let fencedSessions: [DocumentSession] = []
            try beginWorkspaceNamespaceMutation(fencedSessions)
            var mutationEnded = false
            defer {
                if !mutationEnded {
                    endWorkspaceNamespaceMutation(fencedSessions)
                    drainWorkspaceMutationRefreshIfNeeded()
                }
            }
            var recoveryIntent = try prepareWorkspaceCreationRecoveryIntent(
                plan: creationPlan,
                kind: kind
            )
            let outcome = switch kind {
            case .file:
                fileOperations.createFile(
                    using: creationPlan,
                    recordingCreatedArtifact: { artifact in
                        try self.recordWorkspaceCreatedArtifact(
                            artifact,
                            recoveryIntent: &recoveryIntent
                        )
                    }
                )
            case .folder:
                fileOperations.createFolder(
                    using: creationPlan,
                    recordingCreatedArtifact: { artifact in
                        try self.recordWorkspaceCreatedArtifact(
                            artifact,
                            recoveryIntent: &recoveryIntent
                        )
                    }
                )
            }
            endWorkspaceNamespaceMutation(fencedSessions)
            mutationEnded = true
            drainWorkspaceMutationRefreshIfNeeded()
            try finishWorkspaceCreation(outcome, recoveryIntent: recoveryIntent)
        } catch {
            present(error, title: "Workspace Operation Failed")
        }
    }

    func firstEditableNode(in node: WorkspaceFileNode) -> WorkspaceFileNode? {
        if node.isEditableMarkdown {
            return node
        }

        for child in node.children {
            if let match = firstEditableNode(in: child) {
                return match
            }
        }

        return nil
    }
}
