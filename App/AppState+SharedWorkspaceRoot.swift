import Foundation
import WorkspaceKit

struct WorkspaceRootReference {
    weak var context: WorkspaceRootContext?
}

@MainActor
extension AppDocumentRegistry {
    var activeWorkspaceRoots: [WorkspaceRootContext] {
        workspaceRoots = workspaceRoots.filter { $0.value.context != nil }
        return workspaceRoots.values.compactMap(\.context)
    }
}

@MainActor
extension AppState {
    var sharedWorkspaceFacades: [AppState] {
        let facades = workspaceRootContext.facades
        return facades.isEmpty ? [self] : facades
    }

    func connectWorkspaceRootContext() {
        let context = workspaceRootContext
        context.attach(self)
        context.onExportHTMLContextChange = { [weak self, weak context] reason, _, _ in
            guard let context else { return }
            let peers = context.facades
            if peers.isEmpty {
                self?.noteExportHTMLContextChange(reason)
            } else {
                for peer in peers {
                    peer.noteExportHTMLContextChange(reason)
                }
            }
        }
    }

    /// Identity proof reuses the first window's live grant and never starts another scope.
    func matchingWorkspaceRoot(for url: URL) -> WorkspaceRootContext? {
        registry.activeWorkspaceRoots.first { context in
            guard !context.facades.isEmpty, let authority = context.registrationAuthority else {
                return false
            }
            return (try? authority.proveSelectedSpellingNamesCapturedIdentity(selectedRootURL: url)) != nil
        }
    }

    /// Releasing a participant does not advance the shared generation or retire sessions.
    /// Those sessions remain managed by the surviving root and the registry.
    func detachSharedWorkspaceRoot() {
        let context = workspaceRootContext
        context.detach(self)
        completionWorkspaceTask?.cancel()
        completionWorkspaceTask = nil
        workspaceRootURL = nil
        workspaceTree = nil
        workspaceSearchRefreshIntent = nil
        completionWorkspace = .empty
        completionWorkspaceBaseCache = nil
        teardownWorkspaceSearch()
        notifyEditorFindWorkspaceDidClose()
        workspaceRootContext = WorkspaceRootContext()
        connectWorkspaceRootContext()
    }

    func installSharedWorkspaceTreeIfReady() {
        let context = workspaceRootContext
        guard let snapshot = context.workspaceSnapshot,
              context.workspaceInstalledCaptureGeneration == context.workspaceGeneration
        else { return }
        workspaceTree = WorkspaceFileTree.reconcile(
            previous: workspaceTree, snapshot: snapshot, options: .init(showAllFiles: showAllFiles)
        )
        let generation = context.workspaceGeneration
        Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            do {
                try await reconcileSharedWorkspaceWindow(context: context, generation: generation)
            } catch is CancellationError {
                // The participant or root changed while checking its document.
            } catch {
                guard workspaceRootContext === context, workspaceRootURL != nil else { return }
                present(error, title: "Could Not Open Workspace")
            }
        }
    }
}
