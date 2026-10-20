import SwiftUI

struct FileWriteReconciliationBanner: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NoticeBar(
            tone: .caution,
            systemImage: "exclamationmark.shield.fill",
            message: message
        ) {
            Button("Check Again") {
                appState.refreshIndeterminateFileWriteReconciliation()
            }
        }
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
