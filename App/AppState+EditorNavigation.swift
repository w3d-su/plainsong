import EditorKit
import Foundation

/// App-owned ordering, ownership and DEBUG diagnostics for the shared navigation channel.
@MainActor
final class EditorNavigationChannelState {
    var generation: UInt64 = 0
    var lastWorkspaceSearchNavigationID: UInt64?
    #if DEBUG
        var writeHistory: [String] = []
    #endif
}

@MainActor
extension AppState {
    var editorNavigationGeneration: UInt64 {
        get { editorNavigationChannel.generation }
        set { editorNavigationChannel.generation = newValue }
    }

    /// Search query/reload invalidation is scoped to the last workspace-search publication.
    /// Document/text lifecycle and explicit search activation still use the general cancel.
    func cancelPendingWorkspaceSearchNavigationIfNeeded(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard case let .navigate(request)? = editorNavigationCommand,
              request.id == editorNavigationChannel.lastWorkspaceSearchNavigationID
        else { return }
        cancelPendingEditorNavigationIfNeeded(file: file, line: line)
    }

    /// Keep the last channel writes available to hosted timeout diagnostics. Origin is the
    /// caller of the cancellation helper, so reload and lifecycle cancels are distinguishable.
    func publishEditorNavigationCommand(
        _ command: EditorNavigationCommand?,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        #if DEBUG
            editorNavigationChannel.writeHistory.append(
                "\(file):\(line) previous=\(String(describing: editorNavigationCommand)) next=\(String(describing: command))"
            )
            if editorNavigationChannel.writeHistory.count > 24 {
                editorNavigationChannel.writeHistory.removeFirst(editorNavigationChannel.writeHistory.count - 24)
            }
        #endif
        editorNavigationCommand = command
    }
}
