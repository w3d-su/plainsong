import Foundation

/// File activation is synchronous. Carry the navigator's focus choice through the existing
/// anchored/cached/retired activation paths without changing their authority contracts.
enum WorkspaceSelectionFocus {
    @TaskLocal static var requestsEditorFocus = true
}
