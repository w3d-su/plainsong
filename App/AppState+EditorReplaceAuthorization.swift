import EditorKit
import Foundation
import MarkdownCore

/// Why App refuses a Replace for the exact focused session.
///
/// One case per `docs/editor-replace-gates.md` §5.6 state, named for the App state that
/// holds it. This is deliberately **not** `canSave`: save-only conditions (an in-flight
/// save, the recovery-store load failure, a missing URL) must not change whether a source
/// edit is allowed, and a future save-only fence must not silently change editability.
enum EditorReplaceAuthorizationRefusal: Equatable, Sendable {
    /// The session is not App's current document (Replace edits the focused session only).
    case notCurrentSession
    /// The plan's authority stamp (generation, session, source revision) no longer holds.
    case authoritySuperseded

    /// §5.6 row 1 — an external observation or the Reload / Keep Mine banner awaits a choice.
    /// A coherent disk inspection of this session is in flight.
    case externalObservationPending
    /// A conflicting observation is recorded or its Reload / Keep Mine prompt is shown.
    case externalChangeAwaitingChoice

    /// §5.6 row 2 — Reload / Keep Mine captured, read in flight, or not yet converged.
    /// The intent is captured but its read is not running (suspended behind pending
    /// editor source, or waiting to restart).
    case externalResolutionSuspended
    /// The Reload / Keep Mine read is in flight.
    case externalResolutionInFlight
    /// The accepted source is applied but not every live editor installation converged.
    case liveEditorConvergencePending

    /// §5.6 row 3 — any `committedButIndeterminate` write quarantine.
    /// Readable (Reload / Keep Mine) or unavailable (Check Again) alike.
    case indeterminateWriteQuarantine

    // §5.6 row 4 — write fence, indeterminate mutation, recovery fence, pending source.
    case workspaceMutationWriteFence
    case indeterminateWorkspaceMutation
    /// Missing, detached, or text-recovery formerly-backed authority.
    case detachedRecoveryAuthority
    /// Native source or an asynchronous editor mutation has not reached App yet.
    case pendingEditorSource
}

/// App's plain, STTextView-free Replace commit decision over one exact session.
enum EditorReplaceAuthorizationDecision: Equatable, Sendable {
    case allowed
    case refused(EditorReplaceAuthorizationRefusal)
}

/// Where App evaluated authorization for one Replace command.
enum EditorReplaceAuthorizationCheckpoint: Equatable, Sendable {
    /// Command validation, before the command is routed to an editor.
    case validation
    /// EditorKit's commit-time call, immediately before writer preflight.
    case commit
}

/// Records what App answered for one command, so a commit-time refusal keeps its reason.
@MainActor
final class EditorReplaceAuthorizationRecord {
    private(set) var checkpoints: [EditorReplaceAuthorizationCheckpoint] = []
    private(set) var refusal: EditorReplaceAuthorizationRefusal?

    func note(
        _ checkpoint: EditorReplaceAuthorizationCheckpoint,
        _ decision: EditorReplaceAuthorizationDecision
    ) {
        checkpoints.append(checkpoint)
        if case let .refused(reason) = decision {
            refusal = reason
        }
    }
}

@MainActor
extension AppState {
    /// The §5.6 decision for `session`, evaluated fresh. A valid installed untitled or
    /// in-memory session is allowed: only the fences below refuse, never a missing URL.
    func editorReplaceAuthorizationDecision(
        for session: DocumentSession
    ) -> EditorReplaceAuthorizationDecision {
        guard session === currentDocument else { return .refused(.notCurrentSession) }
        if let refusal = editorReplaceRecoveryFenceRefusal(for: session)
            ?? editorReplaceExternalResolutionRefusal(for: session)
        {
            return .refused(refusal)
        }
        return .allowed
    }

    /// §5.6 rows 3–4: quarantine, mutation fences, and recovery-fenced authority.
    private func editorReplaceRecoveryFenceRefusal(
        for session: DocumentSession
    ) -> EditorReplaceAuthorizationRefusal? {
        let sessionIdentity = ObjectIdentifier(session)
        if indeterminateSessionWrites[sessionIdentity] != nil {
            return .indeterminateWriteQuarantine
        }
        if indeterminateWorkspaceMutationSessions.contains(sessionIdentity) {
            return .indeterminateWorkspaceMutation
        }
        if workspaceMutationWriteFences.contains(sessionIdentity) {
            return .workspaceMutationWriteFence
        }
        if let stateURL = sessionStateURL(for: session),
           detachedSessionURLs.contains(stateURL)
           || missingFilePrompt.map({ exactFileURLSpellingMatches($0.fileURL, stateURL) }) == true
        {
            return .detachedRecoveryAuthority
        }
        return nil
    }

    /// §5.6 rows 1–2 and pending editor source: unsettled external resolution.
    private func editorReplaceExternalResolutionRefusal(
        for session: DocumentSession
    ) -> EditorReplaceAuthorizationRefusal? {
        let sessionIdentity = ObjectIdentifier(session)
        let stateURL = sessionStateURL(for: session)
        if pendingExternalReloadApplications[sessionIdentity] != nil {
            return .liveEditorConvergencePending
        }
        if externalReloadTasks[sessionIdentity] != nil {
            return .externalResolutionInFlight
        }
        if let stateURL, deferredExternalChangeResolutions[stateURL] != nil {
            return .externalResolutionSuspended
        }
        if hasPendingEditorSource(for: session) {
            return .pendingEditorSource
        }
        if let stateURL,
           pendingExternalTexts[stateURL] != nil
           || pendingExternalFileVersions[stateURL] != nil
           || externalChangePrompt.map({ exactFileURLSpellingMatches($0.fileURL, stateURL) }) == true
        {
            return .externalChangeAwaitingChoice
        }
        if externalDiskInspectionTasks[sessionIdentity] != nil {
            return .externalObservationPending
        }
        return nil
    }

    /// The stamp check plus the §5.6 decision, as one answer.
    func editorReplaceAuthorizationDecision(
        for stamp: EditorReplaceAuthorityStamp,
        session: DocumentSession?
    ) -> EditorReplaceAuthorizationDecision {
        guard let session, session === currentDocument else {
            return .refused(.notCurrentSession)
        }
        guard stamp == currentEditorReplaceAuthorityStamp(for: session) else {
            return .refused(.authoritySuperseded)
        }
        return editorReplaceAuthorizationDecision(for: session)
    }

    /// The closure EditorKit calls at commit, immediately before writer preflight and in
    /// the same synchronous turn as the native insert. It is bound to the exact session
    /// and stamp the plan captured, and answers from live App state, never a cached bit.
    func makeEditorReplaceCommitAuthorization(
        stamp: EditorReplaceAuthorityStamp,
        session: DocumentSession,
        record: EditorReplaceAuthorizationRecord
    ) -> EditorReplaceAuthorization {
        EditorReplaceAuthorization { [weak self, weak session] in
            MainActor.assumeIsolated {
                guard let self else {
                    record.note(.commit, .refused(.notCurrentSession))
                    return false
                }
                self.editorFindHost.replaceAuthority.willCheckCommitForTesting?()
                let decision = self.editorReplaceAuthorizationDecision(for: stamp, session: session)
                record.note(.commit, decision)
                return decision == .allowed
            }
        }
    }
}
