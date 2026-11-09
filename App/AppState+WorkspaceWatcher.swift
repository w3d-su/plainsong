import Foundation
import WorkspaceKit

/// Assigned before start, then read on the watcher's queue and the main actor.
private final class WorkspaceEventWatcherBox: @unchecked Sendable {
    weak var watcher: WorkspaceEventWatcher?
}

@MainActor
extension AppState {
    func startSharedWorkspaceWatcher(root: URL) {
        let context = workspaceRootContext
        let box = WorkspaceEventWatcherBox()
        let watcher = WorkspaceEventWatcher(rootURL: root) { [weak context, box, root] in
            Task { @MainActor [weak context] in
                guard let context, let facade = context.facades.first else { return }
                let watcher = box.watcher
                let dropReason: String? = if watcher !== context.workspaceWatcher {
                    "replaced"
                } else if watcher == nil || watcher?.isStopped == true {
                    "stopped"
                } else if !(facade.workspaceRootURL.map { facade.exactFileURLSpellingMatches($0, root) } ?? false) {
                    "rootChanged"
                } else {
                    nil
                }
                let site: (fileID: StaticString, line: UInt) = (#fileID, #line)
                facade.traceWorkspaceWatcherDelivery(
                    dropReason: dropReason, watcher: watcher, fileID: site.fileID, line: site.line
                )
                guard dropReason == nil else { return }
                facade.refreshWorkspaceAfterFileSystemChange(fileID: site.fileID, line: site.line)
            }
        }
        box.watcher = watcher
        workspaceWatcher = watcher
        watcher.start()
    }
}
