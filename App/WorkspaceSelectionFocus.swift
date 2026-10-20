import Foundation

/// Carry the navigator's focus choice through the synchronous activation commit for
/// anchored/cached/retired sessions, including files prepared off the main actor.
enum WorkspaceSelectionFocus {
    @TaskLocal static var requestsEditorFocus = true
}
