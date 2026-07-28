import Foundation
import MarkdownCore

/// App-owned find-bar chrome and focus tokens (independent of workspace-search UI).
///
/// Value type like `WorkspaceSearchUIState`: App mutates via whole-value reassignment
/// so `@Published` on `AppState.editorFindUI` drives view updates.
struct EditorFindUIState: Equatable {
    /// Whether the find bar is visible above the editor.
    var isBarVisible = false
    /// Query field text (source of truth for chrome; controller gets `TextSearchQuery`).
    var queryText = ""
    /// When true, case policy is `.sensitive`; when false, `.smart` (workspace-search Aa).
    var matchCase = false
    var wholeWord = false
    /// Monotonic focus request for the owned AppKit query field.
    var focusRequestID: UInt64 = 0
    /// Last focus request actually consumed by a **key** window's owned query field.
    ///
    /// App-owned, exactly like `WorkspaceSearchUIState.focusAppliedID`: `AppState` is shared
    /// across the `WindowGroup`, so a per-coordinator receipt lets a second window (or a
    /// remounted bar) replay a token the first window already spent. Only a key window whose
    /// owned `NSTextField` is the real first responder may advance this.
    var focusAppliedID: UInt64 = 0
    /// Bumped whenever the field should select-all (⌘F show/re-focus).
    var selectAllRequestID: UInt64 = 0
    /// Last select-all request actually performed by a **key** window's owned query field.
    ///
    /// App-owned for the same reason as `focusAppliedID`: a coordinator-local receipt starts
    /// at zero in every new window, so a second window's first binding update would replay a
    /// spent select-all and the next keystroke would replace the whole query.
    var selectAllAppliedID: UInt64 = 0
    /// Highest request ID that was abandoned without becoming first responder
    /// (e.g. ⇧⌘F took focus, Escape closed the bar). Pending async closures for
    /// `requestID <= focusSupersededID` must no-op. Independent of workspace-search tokens.
    var focusSupersededID: UInt64 = 0
    /// Presentation of session counter (updated from controller).
    var matchCounterText = ""
    var isTruncated = false
    var hasActiveQuery = false

    mutating func requestFocusAndSelectAll() {
        focusRequestID &+= 1
        selectAllRequestID &+= 1
    }

    mutating func requestFocusOnly() {
        focusRequestID &+= 1
    }

    /// Abandon any unapplied focus request without advancing `focusRequestID`
    /// (so workspace-search / other owners keep token independence).
    mutating func supersedePendingFocus() {
        if focusRequestID > focusSupersededID {
            focusSupersededID = focusRequestID
        }
    }

    /// Live arbitration inputs for one focus attempt. Read fresh on every retry iteration —
    /// never captured across an `await`, because key-window and token state both move.
    struct FocusSnapshot: Equatable {
        var requestID: UInt64
        var appliedID: UInt64
        var supersededID: UInt64
        var selectAllRequestID: UInt64
        var selectAllAppliedID: UInt64
        var isBarVisible: Bool
    }

    var focusSnapshot: FocusSnapshot {
        FocusSnapshot(
            requestID: focusRequestID,
            appliedID: focusAppliedID,
            supersededID: focusSupersededID,
            selectAllRequestID: selectAllRequestID,
            selectAllAppliedID: selectAllAppliedID,
            isBarVisible: isBarVisible
        )
    }

    mutating func applySessionPresentation(_ session: EditorFindSession?) {
        guard let session else {
            matchCounterText = ""
            isTruncated = false
            hasActiveQuery = false
            return
        }
        hasActiveQuery = !session.query.pattern.isEmpty
        isTruncated = session.isTruncated
        if session.query.pattern.isEmpty {
            matchCounterText = ""
        } else if session.total == 0 {
            matchCounterText = "No results"
        } else if let ordinal = session.currentOrdinal {
            if session.isTruncated {
                matchCounterText = "\(ordinal) / \(session.total)+"
            } else {
                matchCounterText = "\(ordinal) / \(session.total)"
            }
        } else if session.isTruncated {
            matchCounterText = "0 / \(session.total)+"
        } else {
            matchCounterText = "0 / \(session.total)"
        }
    }

    mutating func resetChromeKeepingQuery() {
        // File switch: bar may stay open; counter clears until rebind completes.
        matchCounterText = ""
        isTruncated = false
    }

    mutating func closeBar() {
        isBarVisible = false
        supersedePendingFocus()
    }

    func makeSearchQuery() -> TextSearchQuery {
        TextSearchQuery(
            pattern: queryText,
            caseSensitivity: matchCase ? .sensitive : .smart,
            wholeWord: wholeWord
        )
    }
}

/// Which find-bar control currently holds SwiftUI keyboard focus.
///
/// The bar's toggles and buttons are plain SwiftUI, so under Full Keyboard Access there is no
/// dedicated AppKit view to detect: macOS SwiftUI flattens the bar and the editor into one
/// hosting view, which is why an AppKit ancestor walk cannot tell "focus is on Aa" from
/// "focus is in the sidebar". Observing SwiftUI's own focus is the only reliable signal.
/// This is **observation only** — focus for the query field is still driven through the owned
/// AppKit `NSTextField`, per the WS3C precedent against `FocusState`-driven focus.
enum EditorFindChromeFocus: Hashable {
    case matchCase
    case wholeWord
    case previous
    case next
    case done
}

/// Pure focus arbitration for the owned find query field.
///
/// Mirrors `WorkspaceSearchFocusArbitration`: only a key window may apply a request, and
/// only when it is newer than both App-owned receipts. Background windows sharing the same
/// `AppState` must never consume a token.
enum EditorFindFocusArbitration {
    static func shouldApplyFocus(
        requestID: UInt64,
        appliedID: UInt64,
        supersededID: UInt64,
        isKeyWindow: Bool
    ) -> Bool {
        isKeyWindow
            && requestID > 0
            && requestID > appliedID
            && requestID > supersededID
    }

    /// Whether an attempt is still worth retrying: the request is current and neither
    /// consumed nor abandoned. Key-window state is deliberately excluded — a bar that has
    /// not mounted yet, or a window that is not key *yet*, must keep waiting.
    static func shouldKeepRetrying(
        requestID: UInt64,
        snapshot: EditorFindUIState.FocusSnapshot
    ) -> Bool {
        snapshot.isBarVisible
            && snapshot.requestID == requestID
            && requestID > snapshot.appliedID
            && requestID > snapshot.supersededID
    }
}
