import Foundation
import MarkdownCore

struct EditorFindReplacementArm: Equatable {
    let plan: EditorReplaceOneMatchPlan
    let preWriteRevision: UInt64
}

extension EditorFindController {
    var hasArmedReplacementPublication: Bool {
        armedReplacementPublication != nil
    }

    var armedReplacementPreWriteRevision: UInt64? {
        armedReplacementPublication?.preWriteRevision
    }

    func armReplacementPublication(
        plan: EditorReplaceOneMatchPlan,
        preWriteRevision: UInt64
    ) {
        armedReplacementPublication = EditorFindReplacementArm(
            plan: plan,
            preWriteRevision: preWriteRevision
        )
    }

    func disarmReplacementPublication() {
        armedReplacementPublication = nil
    }

    /// Literal-identical continuation. Installs the retained session without a rescan.
    func installUnchangedContinuation(_ continuation: EditorReplaceContinuation) {
        session = continuation.session
        caretAnchorUTF16 = continuation.resumeUTF16
        shouldActivateCurrentOnNextStep = false
        pendingStepIntent = nil
        if let match = continuation.session.currentMatch {
            emitNavigation(to: match.range)
        } else {
            emitNavigation(to: continuation.collapsedSelection)
        }
        notifySessionDidChange()
    }

    func scheduleReplacement(
        plan: EditorReplaceOneMatchPlan,
        text: String,
        revision: UInt64
    ) {
        lastScheduleReason = .replacement(resumeUTF16: plan.resumeUTF16)
        replacementScheduleCount &+= 1
        cancelInFlightWork()
        queryGeneration &+= 1
        let generation = queryGeneration
        documentBinding = EditorFindDocumentBinding(
            identity: documentBinding.identity,
            text: text,
            revision: revision
        )
        let debounce = debounceNanoseconds
        let fence = EditorFindMatchFence(
            documentIdentity: documentBinding.identity,
            sourceRevision: revision,
            queryGeneration: generation
        )
        session = nil
        pendingNavigationCommand = nil
        shouldActivateCurrentOnNextStep = false
        pendingStepIntent = nil
        notifySessionDidChange()

        debounceTask = Task { @MainActor [weak self] in
            if debounce > 0 {
                try? await Task.sleep(nanoseconds: debounce)
            }
            guard !Task.isCancelled, let self else { return }
            runReplacementMatch(plan: plan, text: text, fence: fence)
        }
    }

    private func runReplacementMatch(
        plan: EditorReplaceOneMatchPlan,
        text: String,
        fence: EditorFindMatchFence
    ) {
        matchTask?.cancel()
        let hold = testMatchHold
        let forceMain = forceMainActorMatchForTesting
        matchTask = Task { @MainActor [weak self] in
            let searched: (EditorReplaceContinuation, Bool)
            if forceMain {
                if let hold {
                    await hold.waitIfHeld()
                }
                searched = (
                    EditorReplaceContinuationPlanning.afterOneReplace(
                        plan: plan,
                        postWriteSource: text
                    ),
                    Self.currentlyOffMainThread()
                )
            } else {
                searched = await Task.detached(priority: .userInitiated) {
                    if let hold {
                        await hold.waitIfHeld()
                    }
                    return (
                        EditorReplaceContinuationPlanning.afterOneReplace(
                            plan: plan,
                            postWriteSource: text
                        ),
                        EditorFindController.currentlyOffMainThread()
                    )
                }.value
            }

            guard let self else { return }
            replacementEngineInvocationCount &+= 1
            lastMatchRanOffMain = searched.1
            let current = EditorFindMatchFence(
                documentIdentity: documentBinding.identity,
                sourceRevision: documentBinding.revision,
                queryGeneration: queryGeneration
            )
            guard current == fence else {
                droppedStaleMatchCount &+= 1
                return
            }
            completedMatchCount &+= 1
            applyReplacementContinuation(searched.0)
        }
    }

    private func applyReplacementContinuation(_ continuation: EditorReplaceContinuation) {
        session = continuation.session
        caretAnchorUTF16 = continuation.resumeUTF16
        shouldActivateCurrentOnNextStep = false
        pendingStepIntent = nil
        if let match = continuation.session.currentMatch {
            emitNavigation(to: match.range)
        } else {
            emitNavigation(to: continuation.collapsedSelection)
        }
        notifySessionDidChange()
    }
}
