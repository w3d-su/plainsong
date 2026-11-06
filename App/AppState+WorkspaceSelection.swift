import Foundation
import MarkdownCore
import WorkspaceKit

struct PreparedWorkspaceNodeSelection: Sendable {
    let nodeID: WorkspaceFileNode.ID
    let generation: UInt64
    let location: WorkspaceFileSystemLocation
    let read: PreparedEditorImageAssetDocumentRead
    let sessionState: WorkspaceNodeSelectionSessionState
}

struct WorkspaceNodeSelectionSessionState: Sendable, Equatable {
    let session: DocumentSession?
    let version: Int?
    let isDirty: Bool?
    let boundIdentity: WorkspaceFileSystemIdentity?
    let boundSHA256Digest: String?
    let lifecycleGeneration: UInt64?
    let diskEventGeneration: UInt64?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session === rhs.session && lhs.version == rhs.version && lhs.isDirty == rhs.isDirty
            && lhs.boundIdentity == rhs.boundIdentity && lhs.boundSHA256Digest == rhs.boundSHA256Digest
            && lhs.lifecycleGeneration == rhs.lifecycleGeneration
            && lhs.diskEventGeneration == rhs.diskEventGeneration
    }
}

@MainActor
extension AppState {
    /// Menu/jump-bar callers retain synchronous activation. Publish the row only after
    /// the file was actually opened, so a read failure leaves the previous file selected.
    @discardableResult
    func selectWorkspaceNode(
        id nodeID: WorkspaceFileNode.ID,
        requestingEditorFocus: Bool = true
    ) -> Bool {
        guard let location = workspaceNodeSelectionLocation(id: nodeID) else { return false }
        do {
            try validateWorkspaceMutationRecoveryStoresLoaded(at: location.fileURL)
            let sessionState = workspaceNodeSelectionSessionState(at: location)
            let read = try prepareEditorImageAssetDocumentRead(fileStore: fileStore, at: location)
            return try commitWorkspaceNodeSelection(
                PreparedWorkspaceNodeSelection(
                    nodeID: nodeID, generation: workspaceGeneration, location: location,
                    read: read, sessionState: sessionState
                ),
                requestingEditorFocus: requestingEditorFocus
            )
        } catch {
            present(error, title: "Could Not Open File")
            return false
        }
    }

    /// Files-list reads must not block the main actor. The returned preparation carries
    /// the capture generation; commit rechecks it after this suspension before publishing.
    func prepareWorkspaceNodeSelection(
        id nodeID: WorkspaceFileNode.ID,
        beforeRead: (@Sendable () -> Void)? = nil
    ) async throws -> PreparedWorkspaceNodeSelection? {
        guard let location = workspaceNodeSelectionLocation(id: nodeID) else { return nil }
        try validateWorkspaceMutationRecoveryStoresLoaded(at: location.fileURL)
        let generation = workspaceGeneration
        let sessionState = workspaceNodeSelectionSessionState(at: location)
        let fileStore = fileStore
        return try await withThrowingTaskGroup(of: PreparedWorkspaceNodeSelection.self) { group in
            group.addTask(priority: .userInitiated) {
                try Task.checkCancellation()
                beforeRead?()
                try Task.checkCancellation()
                let read = try prepareEditorImageAssetDocumentRead(fileStore: fileStore, at: location)
                try Task.checkCancellation()
                return PreparedWorkspaceNodeSelection(
                    nodeID: nodeID, generation: generation, location: location,
                    read: read, sessionState: sessionState
                )
            }
            return try await group.next()
        }
    }

    @discardableResult
    func commitWorkspaceNodeSelection(
        _ prepared: PreparedWorkspaceNodeSelection,
        requestingEditorFocus: Bool
    ) throws -> Bool {
        guard prepared.generation == workspaceGeneration,
              workspaceInstalledCaptureGeneration == prepared.generation,
              let location = workspaceNodeSelectionLocation(id: prepared.nodeID),
              location == prepared.location,
              workspaceNodeSelectionSessionState(at: location) == prepared.sessionState
        else {
            return false
        }
        let result = prepared.read.result
        let activation = try prepareAnchoredFileSessionActivation(
            file: result.file,
            at: location,
            metadata: result.metadata,
            sha256Digest: result.sha256Digest,
            preparedImageAssetAuthority: prepared.read.preparedAuthority
        )
        WorkspaceSelectionFocus.$requestsEditorFocus.withValue(requestingEditorFocus) {
            commitAnchoredFileSessionActivation(activation)
        }
        workspaceTree?.selectNode(id: prepared.nodeID)
        return true
    }

    private func workspaceNodeSelectionSessionState(
        at location: WorkspaceFileSystemLocation
    ) -> WorkspaceNodeSelectionSessionState {
        let session = registry.warmSession(at: location.fileURL)
            ?? retiredEditorDocumentSessions[location.fileURL]?.session
        let binding = session.flatMap { anchoredSessionFileBinding(for: $0) }
        return WorkspaceNodeSelectionSessionState(
            session: session,
            version: session?.version,
            isDirty: session?.isDirty,
            boundIdentity: binding?.identity,
            boundSHA256Digest: binding?.sha256Digest,
            lifecycleGeneration: session.map { currentSessionLifecycleGeneration(for: $0) },
            diskEventGeneration: session.map { currentExternalDiskEventGeneration(for: $0) }
        )
    }

    private func workspaceNodeSelectionLocation(
        id nodeID: WorkspaceFileNode.ID
    ) -> WorkspaceFileSystemLocation? {
        guard let node = workspaceTree?.node(id: nodeID),
              node.isEditableMarkdown,
              let rootAuthority = workspaceSearchRootAuthority,
              workspaceInstalledCaptureGeneration == workspaceGeneration
        else {
            return nil
        }
        return try? rootAuthority.location(relativePath: node.relativePath)
    }
}
