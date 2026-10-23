import Foundation
import WorkspaceCore
import WorkspaceKitIOS

extension IOSDocumentSceneController {
    /// Restores only an opaque record from this scene's existing access service.
    /// The shared adoption helper is delivered by the recovery integration base.
    func openRecent(recordID: UUID, using access: any IOSRecentWorkspaceAccess) async throws {
        guard workspace === access.workspaceProvider else { throw IOSWorkspaceFailure.outsideGrant }
        guard let item = access.recentItems().first(where: { $0.recordID == recordID }) else {
            throw IOSWorkspaceFailure.notFound
        }
        guard item.status == .available else { throw IOSWorkspaceFailure.permissionDenied }
        try Task.checkCancellation()
        try beginTransition()
        defer { finishTransition() }
        try await closeCurrent()
        try Task.checkCancellation()
        guard !isShuttingDown, !isDisposed else { throw IOSDocumentFailure.unavailable }

        let grant = try await access.restoreRecent(recordID: recordID)
        try await installRestoredRecent(grant, recordID: recordID, expectedScope: item.scope, access: access)
    }

    private func installRestoredRecent(
        _ grant: IOSWorkspaceGrant,
        recordID: UUID,
        expectedScope: IOSWorkspaceScope,
        access: any IOSRecentWorkspaceAccess
    ) async throws {
        var adopted = false
        do {
            let fresh = try await recentSnapshot(grant, expectedScope: expectedScope)
            try Task.checkCancellation()
            guard !isShuttingDown, !isDisposed,
                  access.recentItems().contains(where: { $0.recordID == recordID && $0.status == .available })
            else { throw IOSWorkspaceFailure.grantChanged }
            // No await between the final context guards and atomic grant adoption.
            try adoptCurrentGrant(grant, snapshot: fresh)
            adopted = true
            try await installSingleRecent(grant)
        } catch {
            if !adopted {
                _ = workspace.invalidate(grant.workspaceID)
            } else if handle == nil, currentGrant?.workspaceID == grant.workspaceID {
                releaseCurrentGrant()
            }
            throw error
        }
    }

    private func recentSnapshot(
        _ grant: IOSWorkspaceGrant, expectedScope: IOSWorkspaceScope
    ) async throws -> IOSWorkspaceSnapshot {
        guard grant.scope == expectedScope else { throw IOSWorkspaceFailure.outsideGrant }
        try Task.checkCancellation()
        guard !isShuttingDown, !isDisposed else { throw IOSDocumentFailure.unavailable }
        return try await workspace.refresh(grant)
    }

    private func installSingleRecent(_ grant: IOSWorkspaceGrant) async throws {
        guard grant.scope == .singleFile else { return }
        guard let location = documentLocation(for: grant.rootURL) else {
            throw IOSDocumentFailure.access(.unsupportedType)
        }
        try await install(location, initialText: nil)
        if Task.isCancelled {
            // A provider-returned writer cannot be dropped. Retain its
            // admission/session read-only until the next safe close.
            _ = workspace.invalidate(grant.workspaceID)
            throw CancellationError()
        }
    }
}
