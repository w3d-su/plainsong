import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func scheduleCompletionWorkspaceRefresh(debounceNanoseconds: UInt64 = 0) {
        completionWorkspaceTask?.cancel()

        let rootURL = workspaceRootURL
        let tree = workspaceTree
        let fileURL = currentDocument.fileURL
        let text = currentDocument.text

        completionWorkspaceTask = Task { @MainActor [weak self] in
            if debounceNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: debounceNanoseconds)
                } catch {
                    return
                }
            }

            let workspace = await Task.detached(priority: .utility) {
                do {
                    return try CompletionWorkspaceProvider().workspace(
                        rootURL: rootURL,
                        currentFileURL: fileURL,
                        currentText: text,
                        tree: tree
                    )
                } catch {
                    return CompletionWorkspace(
                        currentFilePath: fileURL?.lastPathComponent,
                        currentFileHeadingAnchors: []
                    )
                }
            }.value

            guard let self, !Task.isCancelled else { return }
            completionWorkspace = workspace
        }
    }
}
