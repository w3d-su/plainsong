import Foundation
import MarkdownCore

/// Sidebar content mode for the fixed-width workspace shell (WS3C).
enum WorkspaceSidebarMode: String, CaseIterable, Equatable {
    case files
    case search
}

/// App-owned search chrome state (mode, query, case/word, focus tokens).
///
/// Focus is **not** SwiftUI `FocusState`: the Search query control is an owned AppKit
/// `NSTextField` (`WorkspaceSearchQueryField`). Views route focus via key-window eligibility
/// (`WindowKeyStateTracker` / `NSWindow`) and mark `focusAppliedID` only after that field is
/// the real first responder.
struct WorkspaceSearchUIState: Equatable {
    var mode: WorkspaceSidebarMode = .files
    /// Raw query field text. Empty clears the active workspace search.
    var queryText: String = ""
    /// When true, force case-sensitive matching; when false, use smart case.
    var matchCase: Bool = false
    var wholeWord: Bool = false
    /// Monotonic focus *request* token. Each request to open or re-focus Search increments it.
    var focusRequestID: UInt64 = 0
    /// Last focus request successfully applied by a **key** window. Background windows must not
    /// advance this; only a key-window receipt after the owned Search `NSTextField` is first
    /// responder may mark applied.
    var focusAppliedID: UInt64 = 0
    /// When non-`nil`, a non-empty UI query was deferred because search was not ready for this
    /// workspace generation. Only that pending install may auto-resume; ordinary reloads do not
    /// re-arm this from a mere non-empty query field. Active-query refresh uses a separate,
    /// root-bound intent.
    var pendingResumeGeneration: UInt64?

    /// Maps UI case/word toggles onto the existing `TextSearchQuery` contract.
    ///
    /// Explicit case-insensitive is supported by MarkdownCore but not exposed in v1 UI.
    func makeTextSearchQuery() -> TextSearchQuery {
        TextSearchQuery(
            pattern: queryText,
            caseSensitivity: matchCase ? .sensitive : .smart,
            wholeWord: wholeWord
        )
    }
}

/// Pure focus arbitration for the Search field.
///
/// Only the key window may apply a request, and only when `requestID` is newer than the
/// App-owned applied receipt. Background windows that share AppState must not consume tokens.
enum WorkspaceSearchFocusArbitration {
    static func shouldApplyFocus(
        requestID: UInt64,
        appliedID: UInt64,
        isKeyWindow: Bool
    ) -> Bool {
        isKeyWindow && requestID > 0 && requestID > appliedID
    }
}
