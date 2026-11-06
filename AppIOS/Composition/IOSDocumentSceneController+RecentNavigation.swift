import Foundation
import WorkspaceKitIOS

/// One pending explicit navigation, carrying only the already-held grant that
/// a Files row needs. It cannot mint authority or revive an invalidated scope.
@MainActor
struct IOSPendingRecentNavigation {
    let id: UUID
    let grant: IOSWorkspaceGrant?
    let continuation: CheckedContinuation<Void, Error>

    func preserves(_ current: IOSWorkspaceGrant) -> Bool {
        grant?.workspaceID == current.workspaceID && grant?.accessGeneration == current.accessGeneration
    }
}

extension IOSDocumentSceneController {
    /// A picker/OS URL or Files row supersedes a suspended Recent operation.
    /// Wait for its provider and any safe close to drain, retaining only the
    /// latest request. Other scene transitions keep their existing busy refusal.
    func waitForRecentTransition(preserving grant: IOSWorkspaceGrant?) async throws {
        try Task.checkCancellation()
        guard recentTransitionActive else { return }
        recentTransitionSuperseded = true
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let previous = pendingRecentNavigation
                pendingRecentNavigation = IOSPendingRecentNavigation(id: id, grant: grant,
                                                                     continuation: continuation)
                previous?.continuation.resume(throwing: CancellationError())
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRecentNavigation(id)
            }
        }
    }

    func checkRecentTransition() throws {
        try Task.checkCancellation()
        guard !recentTransitionSuperseded else { throw CancellationError() }
    }

    func finishRecentTransition() {
        recentTransitionActive = false
        recentTransitionSuperseded = false
        let pending = pendingRecentNavigation
        pendingRecentNavigation = nil
        finishTransition()
        pending?.continuation.resume()
    }

    private func cancelRecentNavigation(_ id: UUID) {
        guard let pending = pendingRecentNavigation, pending.id == id else { return }
        pendingRecentNavigation = nil
        pending.continuation.resume(throwing: CancellationError())
    }
}
