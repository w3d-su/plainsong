import MarkdownCore

/// Owns generation-bound steps and counter-only activation without exposing storage.
struct EditorFindStepIntentState {
    /// After non-navigating recompute (edit/rebind), first next/previous activates the
    /// current ordinal instead of stepping past it.
    private var shouldActivateCurrentOnNextStep = false
    /// Next/previous pressed while `session == nil` (debounce / in-flight). Applied once
    /// when *that same* generation completes — does **not** re-push the query (avoids
    /// restarting debounce and losing reverse intent).
    ///
    /// Bound to `queryGeneration` so a later query/edit/rebind can never consume a step
    /// recorded against superseded results, and carries a net signed count so repeated
    /// presses during one debounce are not compressed into a single step.
    private var pendingStepIntent: PendingStepIntent?

    private struct PendingStepIntent: Equatable {
        let generation: UInt64
        /// Direction of the **first** press (`+1` next, `-1` previous).
        ///
        /// A counter-only generation spends its first press activating the current ordinal,
        /// so only the presses after it move. The net count alone cannot express that:
        /// next-then-previous nets zero but must still end one match back, and
        /// previous-then-next nets zero but must end one match forward.
        let firstDirection: Int
        /// Net signed steps: positive = next, negative = previous.
        var netSteps: Int
    }

    mutating func clear() {
        shouldActivateCurrentOnNextStep = false
        pendingStepIntent = nil
    }

    mutating func clearPendingSteps() {
        pendingStepIntent = nil
    }

    mutating func activateCurrent() {
        shouldActivateCurrentOnNextStep = false
    }

    mutating func consumeCurrentActivation() -> Bool {
        guard shouldActivateCurrentOnNextStep else { return false }
        shouldActivateCurrentOnNextStep = false
        return true
    }

    mutating func record(_ delta: Int, generation: UInt64, hasQuery: Bool) {
        recordPendingStep(delta, generation: generation, hasQuery: hasQuery)
    }

    mutating func resolve(
        _ session: EditorFindSession, generation: UInt64, shouldNavigate: Bool
    ) -> (session: EditorFindSession, emitsNavigation: Bool) {
        if let intent = pendingStepIntent, intent.generation == generation {
            clear()
            return (applyPendingStepIntent(intent, on: session, queryWouldNavigate: shouldNavigate), true)
        } else if shouldNavigate {
            shouldActivateCurrentOnNextStep = false
            return (session, true)
        } else {
            shouldActivateCurrentOnNextStep = session.currentMatch != nil
            return (session, false)
        }
    }

    mutating func resolveContinuation(_ session: EditorFindSession, generation: UInt64?) -> EditorFindSession {
        var resolved = session
        if let generation, let intent = pendingStepIntent, intent.generation == generation {
            resolved = resolved.stepped(by: intent.netSteps)
        }
        clear()
        return resolved
    }

    /// Accumulates a step pressed while the current generation is still computing.
    ///
    /// Bound to the in-flight `generation`; a step recorded here is discarded if a
    /// newer query/edit/rebind supersedes that generation. The net count is clamped so a
    /// pathological press rate cannot overflow — any magnitude past one full cycle wraps
    /// to the same ordinal anyway.
    private mutating func recordPendingStep(_ delta: Int, generation: UInt64, hasQuery: Bool) {
        guard hasQuery else { return }
        let ceiling = EditorFindLimits.retainedMatchCeiling
        if var intent = pendingStepIntent, intent.generation == generation {
            intent.netSteps = min(ceiling, max(-ceiling, intent.netSteps &+ delta))
            pendingStepIntent = intent
        } else {
            pendingStepIntent = PendingStepIntent(
                generation: generation,
                firstDirection: delta,
                netSteps: delta
            )
        }
    }

    private func applyPendingStepIntent(
        _ intent: PendingStepIntent,
        on newSession: EditorFindSession,
        queryWouldNavigate: Bool
    ) -> EditorFindSession {
        // A navigating query already resolves to the anchor match, so every recorded press
        // is a step past it. A counter-only generation (edit / rebind / ⌘E) has not moved
        // the selection yet, so the *first* press activates the current ordinal and only the
        // presses after it step — which is why the first press's direction is retained
        // separately from the net: next-then-previous nets zero but must still end one match
        // back, and previous-then-next must end one match forward.
        let steps = queryWouldNavigate
            ? intent.netSteps
            : intent.netSteps - intent.firstDirection
        return steps == 0 ? newSession : newSession.stepped(by: steps)
    }
}
