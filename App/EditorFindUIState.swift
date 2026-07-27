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
    /// Bumped whenever the field should select-all (⌘F show/re-focus).
    var selectAllRequestID: UInt64 = 0
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
