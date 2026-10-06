import EditorKit
import Foundation
import MarkdownCore

/// One user-visible replacement-row message (`docs/editor-replace-gates.md` §5.1, R8).
///
/// `kind` selects the stable accessibility identifier and the symbol beside the text. The text
/// itself always carries the meaning, so no state is conveyed by color alone.
struct EditorReplaceStatus: Equatable {
    enum Kind: Equatable {
        /// An action finished: "No changes", "Changed X of Y matches", Cancel, interruption.
        case result
        /// A per-reason refusal that is not an App authority fence (IME, stale search, …).
        case refusal
        /// A §5.6 authority fence. `externalObservationPending` is the transient case.
        case blocked
        /// The retained Find session is truncated; Replace All refuses.
        case overflow
    }

    let kind: Kind
    let text: String
    /// The §5.6 fence behind a `.blocked` message, so it can be withdrawn once the fence clears.
    var blockedReason: EditorReplaceAuthorizationRefusal?

    /// The in-flight disk inspection after an autosave: momentary, not a lock.
    var isTransient: Bool {
        blockedReason == .externalObservationPending
    }
}

/// Pure mapping from plain Replace results to row text. No AppKit, no state.
enum EditorReplaceStatusText {
    static let applying = "Applying…"
    static let noChanges = "No changes"
    static let overflow = "More than 10,000 matches; narrow the search."
    static let cancelled = "Replace All cancelled"
    static let markedText = "Finish text input before replacing"
    static let replacedOne = "Replaced 1 match"

    static func preparing(completed: Int, total: Int) -> String {
        "Preparing \(completed) / \(total)"
    }

    static func changed(_ changed: Int, of total: Int) -> String {
        "Changed \(changed) of \(total) matches"
    }

    static func progress(_ activity: EditorReplaceActivity) -> String? {
        switch activity {
        case .idle: nil
        case let .preparing(completed, total): preparing(completed: completed, total: total)
        case .applying: applying
        }
    }

    /// Field error for an invalid replacement value; `nil` when it is valid (empty is valid).
    static func fieldError(_ validity: EditorReplaceValueValidity) -> String? {
        switch validity {
        case .valid:
            nil
        case .exceedsMaximumUTF16Length:
            // The limit is in UTF-16 code units; most emoji and some CJK characters use two.
            "Replacement is too long: the limit is \(EditorReplaceLimits.maximumReplacementUTF16Length) "
                + "text units, and most emoji count as 2"
        case .containsNewline:
            "Replacement must be a single line"
        }
    }

    static func status(for result: EditorReplaceCommandResult) -> EditorReplaceStatus? {
        switch result {
        case let .ineligible(reason): ineligible(reason)
        case .markedText: refusal(markedText)
        case let .refused(reason): blocked(reason)
        case .notDelivered: refusal("Replace needs this window’s editor")
        case let .delivered(outcome): status(for: outcome)
        }
    }

    static func status(for result: EditorReplaceBatchCommandResult) -> EditorReplaceStatus? {
        switch result {
        case let .ineligible(reason): ineligible(reason)
        case let .refused(reason): blocked(reason)
        case .notDelivered: refusal("Replace All needs this window’s editor")
        case let .invalidPlan(reason): planRefusal(reason)
        case .cancelled: EditorReplaceStatus(kind: .result, text: cancelled)
        case .superseded: interrupted
        case .markedText: refusal(markedText)
        case let .delivered(outcome): status(for: outcome)
        }
    }

    private static func status(for outcome: EditorReplaceBatchOutcome) -> EditorReplaceStatus {
        switch outcome {
        // EditorKit returns `.noChanges` only when every match is literally identical.
        case .noChanges: EditorReplaceStatus(kind: .result, text: noChanges)
        case let .replaced(plan): EditorReplaceStatus(
                kind: .result,
                text: changed(plan.changedCount, of: plan.totalCount)
            )
        case .unverifiedWrite: unverified
        case let .refused(reason): batchRefusal(reason)
        }
    }

    /// One sentence per §5.6 fence. The in-flight disk inspection after every autosave is a
    /// momentary state, so it says to try again rather than reporting a failure.
    static func blocked(_ reason: EditorReplaceAuthorizationRefusal) -> EditorReplaceStatus {
        let text = switch reason {
        case .notCurrentSession, .authoritySuperseded:
            "Replace was interrupted; try again"
        case .externalObservationPending:
            "Checking the file for outside changes; try again in a moment"
        case .externalChangeAwaitingChoice:
            "The file changed on disk; choose Reload or Keep Mine first"
        case .externalResolutionSuspended, .externalResolutionInFlight, .liveEditorConvergencePending:
            "The file is reloading; Replace waits until it finishes"
        case .indeterminateWriteQuarantine:
            "A save could not be confirmed; resolve the file before replacing"
        case .workspaceMutationWriteFence:
            "A file operation is in progress; Replace waits until it finishes"
        case .indeterminateWorkspaceMutation:
            "A file operation could not be confirmed; Replace is unavailable"
        case .detachedRecoveryAuthority:
            "The file is missing or detached; Replace is unavailable"
        case .pendingEditorSource:
            "The editor is still publishing changes; try again"
        }
        return EditorReplaceStatus(kind: .blocked, text: text, blockedReason: reason)
    }

    private static let interrupted = EditorReplaceStatus(
        kind: .result,
        text: "Replace All stopped because the search or document changed"
    )
    private static let unverified = EditorReplaceStatus(
        kind: .result,
        text: "The document changed during Replace; check the result"
    )
    private static let searchUpdating = "The search is updating; try again"

    private static func refusal(_ text: String) -> EditorReplaceStatus {
        EditorReplaceStatus(kind: .refusal, text: text)
    }

    private static func ineligible(_ reason: EditorReplaceIneligibility) -> EditorReplaceStatus {
        switch reason {
        case .findBarHidden, .replaceRowCollapsed: refusal("Show Find and Replace first")
        case .noFindSession: refusal(searchUpdating)
        }
    }

    private static func status(for outcome: EditorReplaceOutcome) -> EditorReplaceStatus? {
        switch outcome {
        // The first action only selects the match; the counter and selection say so.
        case .navigatedToCurrentMatch: nil
        case .replaced: EditorReplaceStatus(kind: .result, text: replacedOne)
        case .advancedIdentical: EditorReplaceStatus(kind: .result, text: noChanges)
        case .unverifiedWrite: unverified
        case let .refused(reason): singleRefusal(reason)
        }
    }

    private static func singleRefusal(_ reason: EditorReplaceRefusal) -> EditorReplaceStatus {
        switch reason {
        case .staleIdentity, .staleRevision, .staleQueryGeneration, .staleSession:
            refusal(searchUpdating)
        case .noCurrentMatch: refusal("No current match; use Find Next first")
        case .markedText: refusal(markedText)
        case .unauthorized: blocked(.authoritySuperseded)
        case .wysiwygRangeNotRevealed: refusal("The match is still hidden; Replace again once it is shown")
        case let .invalidPlan(plan): planRefusal(plan)
        case .writerPreflightFailed: refusal("The editor was not ready; try again")
        case .writeNotApplied: refusal("The change was not applied")
        }
    }

    private static func batchRefusal(_ reason: EditorReplaceBatchRefusal) -> EditorReplaceStatus {
        switch reason {
        case .staleIdentity, .staleRevision, .staleQueryGeneration, .staleSession: refusal(searchUpdating)
        case .superseded: interrupted
        case .markedText: refusal(markedText)
        case .unauthorized: blocked(.authoritySuperseded)
        case let .invalidPlan(plan): planRefusal(plan)
        case .writerPreflightFailed: refusal("The editor was not ready; try again")
        case .writeNotApplied: refusal("The change was not applied")
        }
    }

    private static func planRefusal(_ reason: EditorReplacePlanRefusal) -> EditorReplaceStatus {
        switch reason {
        case let .invalidReplacement(validity): refusal(fieldError(validity) ?? searchUpdating)
        case .emptySession: refusal("No matches")
        case .noCurrentMatch: refusal("No current match; use Find Next first")
        case .truncatedSession: EditorReplaceStatus(kind: .overflow, text: overflow)
        case .projectedLengthOverflow: refusal("The result would be too large")
        }
    }
}
