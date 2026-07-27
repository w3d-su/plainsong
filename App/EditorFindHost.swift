import EditorKit
import Foundation

/// App-owned in-document find runtime (controller + chrome bookkeeping).
///
/// Stored as one property on `AppState` so the find surface does not inflate
/// `AppState.swift` past the file-length gate. UI chrome is still published by
/// reassigning `ui` through AppState accessors.
@MainActor
final class EditorFindHost {
    let controller = EditorFindController()
    var ui = EditorFindUIState()
    var presentationTask: Task<Void, Never>?
    var lastAppliedNavigationID: UInt64?
    var latestKnownEditorSelection: NSRange?
}
