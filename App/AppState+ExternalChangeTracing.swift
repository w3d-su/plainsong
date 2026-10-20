import Foundation
import MarkdownCore
import WorkspaceKit

/// Handoff 27b/27c DEBUG attribution for external-change producers, kept out of the
/// already-long workspace and external-change files. Both bodies compile out of Release.
@MainActor
extension AppState {
    /// Records which `handleExternalChange` producer ran — the call site forwarded down the
    /// refresh chain — with the authority state at record time.
    func traceExternalChange(
        for session: DocumentSession,
        advancingDiskEvent: Bool,
        fileID: StaticString,
        line: UInt
    ) {
        #if DEBUG
            editorFindHost.traceReplaceBarAction(
                "handleExternalChange file=\(session.fileURL?.lastPathComponent ?? "untitled") "
                    + "advancing=\(advancingDiskEvent) "
                    + "authorityGen=\(editorReplaceAuthorityGeneration) "
                    + "authorization=\(editorReplaceAuthorizationDecision(for: session))",
                fileID: fileID,
                line: line
            )
        #endif
    }

    /// Records a workspace watcher hop's accept/drop decision at the hop's own call site,
    /// the same site the hop forwards into `refreshWorkspaceAfterFileSystemChange`.
    func traceWorkspaceWatcherDelivery(
        dropReason: String?,
        watcher: WorkspaceEventWatcher?,
        fileID: StaticString,
        line: UInt
    ) {
        #if DEBUG
            editorFindHost.traceReplaceBarAction(
                "watcherHop \(dropReason.map { "dropped reason=\($0)" } ?? "accepted") "
                    + "hop=\(watcher.map { String(describing: ObjectIdentifier($0)) } ?? "nil") "
                    + "installed=\(workspaceWatcher.map { String(describing: ObjectIdentifier($0)) } ?? "nil") "
                    + "isStopped=\(watcher.map { String($0.isStopped) } ?? "nil")",
                fileID: fileID,
                line: line
            )
        #endif
    }
}
