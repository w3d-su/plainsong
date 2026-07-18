import SwiftUI

struct WorkspaceMutationRecoveryBanner: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)

            Text(message)
                .font(.callout.weight(.medium))

            if appState.hasWorkspaceMutationRecoveryLoadFailure {
                Button("Stop Tracking") {
                    appState.stopTrackingWorkspaceMutationRecoveryLoadFailure()
                }
            } else {
                if appState.workspaceMutationReconciliationPrompt?.operation != .textRecovery {
                    Button("Check Again") {
                        appState.reconcileCurrentWorkspaceMutationRecovery()
                    }
                }

                Button(secondaryActionTitle) {
                    appState.performWorkspaceMutationRecoverySecondaryAction()
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.14))
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
