import Foundation

@MainActor
extension AppState {
    var workspaceMutationRecoveryBannerPlacement: WorkspaceMutationRecoveryBannerPlacement {
        if hasWorkspaceMutationRecoveryLoadFailure {
            return .global
        }
        guard workspaceMutationReconciliationPrompt != nil else {
            return .hidden
        }
        return hasOpenDocument ? .editor : .global
    }

    var hasWorkspaceMutationRecoveryLoadFailure: Bool {
        workspaceMutationOperationRecoveryLoadFailed ||
            workspaceMutationTextRecoveryLoadFailed
    }

    var workspaceMutationRecoveryLoadFailureMessage: String {
        switch (
            workspaceMutationOperationRecoveryLoadFailed,
            workspaceMutationTextRecoveryLoadFailed
        ) {
        case (true, true):
            "Workspace operation and editor-text recovery could not be loaded. " +
                "File access is paused until the unreadable recovery is preserved separately."
        case (true, false):
            "Workspace operation recovery could not be loaded. " +
                "File access is paused until the unreadable recovery is preserved separately."
        case (false, true):
            "Editor-text recovery could not be loaded. " +
                "File access is paused until the unreadable recovery is preserved separately."
        case (false, false):
            "Workspace recovery is available."
        }
    }

    func validateWorkspaceMutationRecoveryStoresLoaded(
        at url: URL? = nil
    ) throws {
        guard !hasWorkspaceMutationRecoveryLoadFailure else {
            throw AppStateError.workspaceMutationRecoveryUnavailable(
                url
                    ?? workspaceRootURL
                    ?? sessionStateURL(for: currentDocument)
                    ?? currentDocument.fileURL
                    ?? URL(fileURLWithPath: "/")
            )
        }
    }

    func stopTrackingWorkspaceMutationRecoveryLoadFailure() {
        guard hasWorkspaceMutationRecoveryLoadFailure else {
            refreshWorkspaceMutationReconciliationPrompt()
            return
        }

        let textLoadHadFailed = workspaceMutationTextRecoveryLoadFailed
        let operationRecordsWerePending =
            !pendingWorkspaceMutationOperationRecoveryRecords.isEmpty
        do {
            if workspaceMutationOperationRecoveryLoadFailed {
                try workspaceMutationOperationRecoveryStore
                    .quarantineAfterLoadFailure()
                workspaceMutationOperationRecoveryLoadFailed = false
                workspaceMutationOperationRecoveryLoadError = nil
            }
            if workspaceMutationTextRecoveryLoadFailed {
                try workspaceMutationTextRecoveryStore
                    .quarantineAfterLoadFailure()
                workspaceMutationTextRecoveryLoadFailed = false
                workspaceMutationTextRecoveryLoadError = nil
            }
            refreshWorkspaceMutationRecoveryLoadErrors()

            restoreWorkspaceMutationOperationRecoveryIfNeeded()
            if textLoadHadFailed, !operationRecordsWerePending {
                mergeAndPromoteBundledWorkspaceMutationTextRecoveryRecords(
                    from: workspaceMutationOperationRecoveryRecords.values.sorted {
                        if $0.updatedAt != $1.updatedAt {
                            return $0.updatedAt < $1.updatedAt
                        }
                        return $0.id.uuidString < $1.id.uuidString
                    }
                )
            }
            restoreWorkspaceMutationTextRecoveryIfNeeded()
            if presentedError?.title == "Could Not Load Workspace Recovery" {
                presentedError = nil
            }
            refreshWorkspaceMutationReconciliationPrompt()
        } catch {
            refreshWorkspaceMutationRecoveryLoadErrors()
            present(error, title: "Could Not Stop Tracking Workspace Recovery")
        }
    }

    func refreshWorkspaceMutationRecoveryLoadErrors() {
        workspaceMutationRecoveryLoadErrors = [
            workspaceMutationOperationRecoveryLoadError,
            workspaceMutationTextRecoveryLoadError,
        ].compactMap { $0 }
    }
}
