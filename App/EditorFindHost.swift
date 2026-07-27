import AppKit
import EditorKit
import Foundation

/// App-owned in-document find runtime (controller + chrome bookkeeping).
///
/// Stored as one property on `AppState` so the find surface does not inflate
/// `AppState.swift` past the file-length gate. UI chrome is still published by
/// reassigning `ui` through AppState accessors.
/// Cached editor selection for ⌘E / caret anchor.
///
/// Scoped to one document identity **and one source revision**: offsets only mean anything
/// against the exact text they were read from, so a same-URL Reload must invalidate them the
/// same way a document switch does.
struct EditorFindCachedSelection: Equatable {
    let documentIdentity: EditorDocumentIdentity?
    let sourceRevision: Int
    let range: NSRange
}

/// A find-bar chrome focus report, tagged with the window that produced it.
///
/// `AppState` is shared across the `WindowGroup`, and every window's `EditorFindBar` reports
/// its own SwiftUI `FocusState`. Without the window tag, focus left behind in a background
/// window would make ⌘G / ⌘E eligible in whichever window is key.
struct EditorFindChromeFocusReport: Equatable {
    let windowNumber: Int
    let focus: EditorFindChromeFocus
}

@MainActor
final class EditorFindHost {
    let controller = EditorFindController()
    var ui = EditorFindUIState()
    var presentationTask: Task<Void, Never>?
    /// Last find navigation ID already published on `editorNavigationCommand`.
    var lastPublishedFindNavigationID: UInt64?
    /// Selection snapshot for ⌘E / caret — never reuse across document identities or revisions.
    var latestKnownEditorSelection: EditorFindCachedSelection?
    /// Ensures `onSessionDidChange` is wired once to AppState.
    var didInstallSessionObserver = false
    /// Which find-bar control holds SwiftUI focus, and in which window.
    /// Cleared whenever the bar closes or the document/workspace changes.
    var chromeFocus: EditorFindChromeFocusReport?
    /// Test seam: when non-`nil`, replaces key-window first-responder eligibility checks.
    var commandContextOverride: Bool?
    /// Test seam: when non-`nil`, stands in for `NSApp.keyWindow?.windowNumber`.
    ///
    /// Only *which window is key* is stubbed — the report-versus-key comparison that decides
    /// eligibility still runs, so a cross-window regression is observable.
    var keyWindowNumberOverride: Int?
}
