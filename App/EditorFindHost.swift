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
    /// Monotonic Replace authority generation and its diagnostics (Replace PR E).
    let replaceAuthority = EditorReplaceAuthorityState()
    let replaceBatch = EditorReplaceBatchRuntime()
    let replaceMarkedTextOwners = EditorReplaceMarkedTextOwners()
    var ui = EditorFindUIState()
    /// Materialized once per controller session change so ordinary SwiftUI updates do not map
    /// the retained (up to 10,000) match list back into `NSRange`s again.
    var matchHighlightRequest: EditorFindMatchHighlightRequest?
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
    /// silently own eligibility. A window clears only its own entry; every entry is dropped
    /// only where the bar itself goes away (Escape / Done, last document closed, workspace
    /// closed) — **not** on an ordinary document switch, which keeps the bar open per F4b.
    var chromeFocusByWindow: [Int: EditorFindChromeFocus] = [:]
    /// Test seam: when non-`nil`, replaces key-window first-responder eligibility checks.
    var commandContextOverride: Bool?
    /// Test seam: when non-`nil`, stands in for `NSApp.keyWindow?.windowNumber`.
    ///
    /// Only *which window is key* is stubbed — the report-versus-key comparison that decides
    /// eligibility still runs, so a cross-window regression is observable.
    var keyWindowNumberOverride: Int?
    /// Test seam: when non-`nil`, stands in for `NSApp.keyWindow` in the AppKit responder
    /// branch of `isEditorFindCommandContextActive()`. The window's real first responder is
    /// still inspected; only which window is key is designated (hosted tests cannot make a
    /// window really key). An installed override is authoritative even when it returns `nil`.
    var keyWindowOverride: (() -> NSWindow?)?

    // MARK: Replacement row (Replace PR H)

    /// Last result or refusal shown in the replacement row; `nil` when nothing applies.
    var replaceStatus: EditorReplaceStatus?
    /// Advanced by every row action and by every lifecycle reset, so a Replace All that
    /// finishes after either never writes a stale message into the row.
    var replaceStatusSerial: UInt64 = 0
    /// The bar's own Replace All task. Cancellation goes through the batch runtime, not this.
    var replaceAllTask: Task<Void, Never>?
    /// Spoken copy of the last announced status, for tests; announcements are fire-and-forget.
    var lastReplaceAnnouncement: String?
    var didInstallReplacePresentation = false
    var didAnnounceReplacePreparation = false
    var isReplacePresentationPublishPending = false

    init() {
        // An authority advance supersedes every plan; a preparing one stops at once instead
        // of draining to a refusal behind a still-visible progress label.
        replaceAuthority.onAdvance = { [unowned replaceBatch] in
            replaceBatch.supersedeIfPreparing()
        }
    }
}
