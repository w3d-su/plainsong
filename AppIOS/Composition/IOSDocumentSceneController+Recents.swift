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
        recentTransitionActive = true
        recentTransitionSuperseded = false
        defer { finishRecentTransition() }
        try await closeCurrent()
        try checkRecentTransition()
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
            try checkRecentTransition()
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
                let selectedScopeRemainsLive = error is CancellationError && grantIsCurrent &&
                    pendingRecentNavigation?.preserves(grant) == true
                // A transient cloud failure keeps the same restored file
                // selection for Files Refresh/retry, unless this issuance was
                // cancelled, superseded or retired by scene shutdown.
                let pendingFileRemainsLive = !Task.isCancelled && !recentTransitionSuperseded &&
                    !isShuttingDown && !isDisposed && retainsPendingSelection(after: error, grant: grant)
                if !selectedScopeRemainsLive, !pendingFileRemainsLive {
                    releaseCurrentGrant()
                }
            }
            throw error
        }
    }

    private func recentSnapshot(
        _ grant: IOSWorkspaceGrant, expectedScope: IOSWorkspaceScope
    ) async throws -> IOSWorkspaceSnapshot {
        guard grant.scope == expectedScope else { throw IOSWorkspaceFailure.outsideGrant }
        try checkRecentTransition()
        guard !isShuttingDown, !isDisposed else { throw IOSDocumentFailure.unavailable }
        return try await workspace.refresh(grant)
    }

    private func installSingleRecent(_ grant: IOSWorkspaceGrant) async throws {
        guard grant.scope == .singleFile else { return }
        let location = try pickedDocumentLocation(for: grant.rootURL)
        try await install(location, initialText: nil)
        if Task.isCancelled || recentTransitionSuperseded {
            // Drain the returned writer through the normal close path before
            // retiring authority. A retained writer keeps its ticket/session;
            // cancellation never permits another writer to replace it.
            do {
                try await closeCurrent()
            } catch {
                _ = workspace.invalidate(grant.workspaceID)
                throw error
            }
            if pendingRecentNavigation?.preserves(grant) != true {
                releaseCurrentGrant()
            }
            throw CancellationError()
        }
    }
}
