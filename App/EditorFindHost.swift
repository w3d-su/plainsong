import EditorKit
import Foundation

/// App-owned in-document find runtime (controller + chrome bookkeeping).
///
/// Stored as one property on `AppState` so the find surface does not inflate
/// `AppState.swift` past the file-length gate. UI chrome is still published by
/// reassigning `ui` through AppState accessors.
/// Cached editor selection for ⌘E / caret anchor — scoped to one document identity.
struct EditorFindCachedSelection: Equatable {
    let documentIdentity: EditorDocumentIdentity?
    let range: NSRange
}

@MainActor
final class EditorFindHost {
    let controller = EditorFindController()
    var ui = EditorFindUIState()
    var presentationTask: Task<Void, Never>?
    /// Last find navigation ID already published on `editorNavigationCommand`.
    var lastPublishedFindNavigationID: UInt64?
    /// Selection snapshot for ⌘E / caret — never reuse across document identities.
    var latestKnownEditorSelection: EditorFindCachedSelection?
    /// Ensures `onSessionDidChange` is wired once to AppState.
    var didInstallSessionObserver = false
    /// Which find-bar control holds SwiftUI focus, or `nil` when focus is elsewhere.
    /// Cleared whenever the bar closes or the document/workspace changes.
    var chromeFocus: EditorFindChromeFocus?
    /// Test seam: when non-`nil`, replaces key-window first-responder eligibility checks.
    var commandContextOverride: Bool?
    /// Test seam: when non-`nil`, replaces `EditorFindResponderSupport.keyWindowHostsFindBar()`.
    /// Production leaves this `nil` so live AppKit key state is used.
    var keyWindowHostsFindBarOverride: Bool?
}
