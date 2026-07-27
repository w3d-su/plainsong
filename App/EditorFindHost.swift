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
    /// Reported SwiftUI find-bar focus, **keyed by window number**.
    ///
    /// One entry per window: `AppState` is shared across the `WindowGroup` and each window's
    /// bar keeps its own `FocusState`, so a single slot would let whichever window wrote last
    /// silently own eligibility. Cleared entirely when the bar closes or the
    /// document/workspace changes.
    var chromeFocusByWindow: [Int: EditorFindChromeFocus] = [:]
    /// Test seam: when non-`nil`, replaces key-window first-responder eligibility checks.
    var commandContextOverride: Bool?
    /// Test seam: when non-`nil`, stands in for `NSApp.keyWindow?.windowNumber`.
    ///
    /// Only *which window is key* is stubbed — the report-versus-key comparison that decides
    /// eligibility still runs, so a cross-window regression is observable.
    var keyWindowNumberOverride: Int?
}
