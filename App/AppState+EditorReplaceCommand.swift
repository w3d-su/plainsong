import EditorKit
import Foundation
import MarkdownCore

/// A stamped single-Replace plan: everything App captured when the command was validated.
///
/// Single Replace plans and delivers in one synchronous turn, so a plan normally lives for
/// one call. Holding it across a turn (as Replace All's off-main planning will) is safe: the
/// App stamp and the editor stamp fence every later change before any undo group opens.
struct EditorReplacePlan {
    let stamp: EditorReplaceAuthorityStamp
    let editorStamp: EditorReplaceEditorStamp
    let request: EditorReplaceRequest
    weak var session: DocumentSession?
}

/// Why no plan could be made. Nothing was validated against the editor or changed.
enum EditorReplaceIneligibility: Equatable, Sendable {
    case findBarHidden
    /// No retained Find session (no query, or the match is recomputing).
    case noFindSession
}

enum EditorReplacePlanFailure: Error, Equatable {
    case ineligible(EditorReplaceIneligibility)
    case noKeyWindowEditor(EditorReplaceDeliveryRefusal)
}

/// Plain result of one App Replace command. No STTextView type crosses it.
enum EditorReplaceCommandResult: Equatable {
    case ineligible(EditorReplaceIneligibility)
    /// App refused, at command validation or at EditorKit's commit-time check.
    case refused(EditorReplaceAuthorizationRefusal)
    /// No installed key-window editor ran the command.
    case notDelivered(EditorReplaceDeliveryRefusal)
    /// The key window's installed editor ran the executor.
    case delivered(EditorReplaceOutcome)
}

@MainActor
extension AppState {
    /// One explicit Replace of the current match: plan, then deliver in the same turn.
    ///
    /// This is the seam product chrome (PR H) calls. There is no menu item or button yet.
    @discardableResult
    func performEditorReplace(replacement: String) -> EditorReplaceCommandResult {
        switch makeEditorReplacePlan(replacement: replacement) {
        case let .failure(.ineligible(reason)):
            .ineligible(reason)
        case let .failure(.noKeyWindowEditor(reason)):
            .notDelivered(reason)
        case let .success(plan):
            deliverEditorReplacePlan(plan)
        }
    }

    /// Captures the App authority stamp, the key-window editor stamp, and the exact Find
    /// request. Performs no authorization, navigation, or mutation.
    func makeEditorReplacePlan(
        replacement: String
    ) -> Result<EditorReplacePlan, EditorReplacePlanFailure> {
        guard editorFindHost.ui.isBarVisible else {
            return .failure(.ineligible(.findBarHidden))
        }
        let controller = editorFindHost.controller
        guard let findSession = controller.session else {
            return .failure(.ineligible(.noFindSession))
        }
        editorFindHost.replaceAuthority.observeKeyWindowChangesIfNeeded()
        let editorStamp: EditorReplaceEditorStamp
        switch EditorReplaceCommandDispatcher.captureKeyWindowEditorStamp() {
        case let .failure(reason):
            return .failure(.noKeyWindowEditor(reason))
        case let .success(stamp):
            editorStamp = stamp
        }
        let session = currentDocument
        return .success(EditorReplacePlan(
            stamp: currentEditorReplaceAuthorityStamp(for: session),
            editorStamp: editorStamp,
            request: EditorReplaceRequest(
                documentIdentity: controller.documentBinding.identity,
                sourceRevision: controller.documentBinding.revision,
                queryGeneration: controller.queryGeneration,
                session: findSession,
                replacement: replacement
            ),
            session: session
        ))
    }

    /// Validates the plan's authority, then routes it to the key window's installed editor:
    /// the responder chain first, and App's find-chrome fallback exactly where Find uses it.
    func deliverEditorReplacePlan(_ plan: EditorReplacePlan) -> EditorReplaceCommandResult {
        let record = EditorReplaceAuthorizationRecord()
        editorFindHost.replaceAuthority.lastAuthorizationRecord = record
        let validation = editorReplaceAuthorizationDecision(for: plan.stamp, session: plan.session)
        record.note(.validation, validation)
        guard case .allowed = validation, let session = plan.session else {
            return .refused(record.refusal ?? .notCurrentSession)
        }

        let command = EditorReplaceCommand(
            request: plan.request,
            authorization: makeEditorReplaceCommitAuthorization(
                stamp: plan.stamp,
                session: session,
                record: record
            ),
            controller: editorFindHost.controller,
            editorStamp: plan.editorStamp,
            installations: liveEditorDocumentBindingInstallations(for: session)
        )
        var delivery = EditorReplaceCommandDispatcher.send(command)
        if delivery == .notDelivered(.noEditorOnResponderChain),
           isEditorFindCommandContextActive()
        {
            delivery = EditorReplaceCommandDispatcher.sendToKeyWindowEditor(command)
        }

        switch delivery {
        case let .notDelivered(reason):
            return .notDelivered(reason)
        case .delivered(.refused(.unauthorized)):
            return .refused(record.refusal ?? .authoritySuperseded)
        case let .delivered(outcome):
            reconcileEditorFindAfterReplace(outcome)
            return .delivered(outcome)
        }
    }

    /// A writer refusal may have converged a stale view to App's source (§5.6): Find then
    /// recomputes counter-only so a fresh explicit Replace sees the authoritative session.
    private func reconcileEditorFindAfterReplace(_ outcome: EditorReplaceOutcome) {
        switch outcome {
        case .refused(.writerPreflightFailed), .refused(.writeNotApplied), .unverifiedWrite:
            refreshEditorFindCounterFromAppSource()
        default:
            break
        }
    }
}
