import SwiftUI

struct WorkspaceMutationRecoveryBanner: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NoticeBar(
            tone: .caution,
            systemImage: "exclamationmark.triangle.fill",
            message: message
        ) {
            if appState.hasWorkspaceMutationRecoveryLoadFailure {
                Button("Stop Tracking") {
                    appState.stopTrackingWorkspaceMutationRecoveryLoadFailure()
                }
            } else {
                Button(secondaryActionTitle) {
                    appState.performWorkspaceMutationRecoverySecondaryAction()
                }

                if appState.workspaceMutationReconciliationPrompt?.operation != .textRecovery {
                    Button("Check Again") {
                        appState.reconcileCurrentWorkspaceMutationRecovery()
                    }
                }
            }
        }
    }

    private var message: String {
        if appState.hasWorkspaceMutationRecoveryLoadFailure {
            return appState.workspaceMutationRecoveryLoadFailureMessage
        }
        guard let prompt = appState.workspaceMutationReconciliationPrompt else {
            return "Workspace item location must be reconciled."
        }
        return switch prompt.operation {
        case .creation:
            "The creation result for \(prompt.sourceURL.lastPathComponent) is uncertain."
        case .relocation:
            "The final location of \(prompt.sourceURL.lastPathComponent) is uncertain."
        case .textRecovery:
            if prompt.secondaryAction == .stopTracking {
                "The saved copy is safe, but recovery cleanup for " +
                    "\(prompt.sourceURL.lastPathComponent) still needs attention."
            } else {
                "A recovered editor copy of \(prompt.sourceURL.lastPathComponent) is waiting."
            }
        case .trash:
            "The Trash result for \(prompt.sourceURL.lastPathComponent) is uncertain."
        }
    }

    private var secondaryActionTitle: String {
        guard let prompt = appState.workspaceMutationReconciliationPrompt else {
            return "Stop Tracking"
        }
        return switch prompt.secondaryAction {
        case .keepEditorCopy:
            "Keep Editor Copy"
        case .showEditorCopy:
            prompt.operation == .textRecovery ? "Show Recovery Copy" : "Show Editor Copy"
        case .stopTracking:
            "Stop Tracking"
        }
    }
}
