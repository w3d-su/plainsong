import SwiftUI

struct FileWriteReconciliationBanner: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(.orange)

            Text(message)
                .font(.callout.weight(.medium))

            Button("Check Again") {
                appState.refreshIndeterminateFileWriteReconciliation()
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.14))
    }

    private var message: String {
        guard let prompt = appState.indeterminateFileWriteReconciliationPrompt else {
            return "File reconciliation is required."
        }
        return switch prompt.state {
        case .symbolicLink:
            "Saved state is uncertain and the retained path is now a symbolic link. " +
                "Restore a regular file at that exact path, then check again."
        case .notRegularFile:
            "Saved state is uncertain and the retained path is not a regular file. " +
                "Restore a regular file at that exact path, then check again."
        case .unreadable:
            "Saved state is uncertain and the retained path cannot be read. " +
                "Restore read access at that exact path, then check again."
        }
    }
}
