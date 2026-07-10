import Foundation
import MarkdownCore
import WorkspaceKit

@MainActor
extension AppState {
    func scheduleCompletionWorkspaceRefresh(
        debounceNanoseconds: UInt64 = 0,
        workspaceGeneration expectedWorkspaceGeneration: UInt64? = nil
    ) {
        completionWorkspaceTask?.cancel()

        let rootURL = workspaceRootURL
        let snapshot = workspaceSnapshot
        let workspaceGeneration = expectedWorkspaceGeneration ?? workspaceGeneration
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
                if let rootURL, let fileURL, let snapshot {
                    do {
                        return try CompletionWorkspaceProvider().workspace(
                            rootURL: rootURL,
                            currentFileURL: fileURL,
                            currentText: text,
                            snapshot: snapshot
                        )
                    } catch {
                        return CompletionWorkspace(
                            currentFilePath: fileURL.lastPathComponent,
                            currentFileHeadingAnchors: []
                        )
                    }
                } else {
                    do {
                        return try CompletionWorkspaceProvider().workspace(
                            rootURL: nil,
                            currentFileURL: fileURL,
                            currentText: text,
                            tree: nil
                        )
                    } catch {
                        return CompletionWorkspace(
                            currentFilePath: fileURL?.lastPathComponent,
                            currentFileHeadingAnchors: []
                        )
                    }
                }
            }.value

            guard let self,
                  !Task.isCancelled,
                  self.workspaceGeneration == workspaceGeneration
            else {
                return
            }
            completionWorkspace = workspace
        }
    }
}
