import Foundation

public enum EditorReplaceContinuationPlanning {
    /// Source-changing single Replace: one full existing-engine rescan, no wrap.
    public static func afterOneReplace(
        plan: EditorReplaceOneMatchPlan,
        postWriteSource: String
    ) -> EditorReplaceContinuation {
        let rescanned = EditorFindSession.search(
            in: postWriteSource,
            query: plan.query,
            caretAnchorUTF16: plan.resumeUTF16
        )
        return continuation(
            from: rescanned,
            resumeUTF16: plan.resumeUTF16,
            requireStartAtOrAfter: plan.resumeUTF16
        )
    }

    /// Literal-identical single Replace: no rescan; advance in the retained set.
    public static func afterLiteralIdentical(
        plan: EditorReplaceOneMatchPlan,
        session: EditorFindSession
    ) -> EditorReplaceContinuation {
        continuation(
            from: session,
            resumeUTF16: plan.resumeUTF16,
            requireStartAtOrAfter: plan.resumeUTF16
        )
    }

    /// Replace All: one rescan, current always nil, caret mapped through the batch.
    public static func afterBatch(
        plan: EditorReplaceBatchPlan,
        preWriteCurrentMatch: TextSearchMatch?,
        preWriteCaretUTF16: Int,
        postWriteSource: String
    ) -> EditorReplaceContinuation {
        let mapped = mappedCollapsedOffset(
            plan: plan,
            preWriteCurrentMatch: preWriteCurrentMatch,
            preWriteCaretUTF16: preWriteCaretUTF16
        )
        let length = (postWriteSource as NSString).length
        let clamped = min(max(0, mapped), length)
        let rescanned = EditorFindSession.search(
            in: postWriteSource,
            query: plan.query,
            caretAnchorUTF16: clamped
        ).withUnresolvedCurrent(caretAnchorUTF16: clamped)
        return EditorReplaceContinuation(
            session: rescanned,
            resumeUTF16: clamped,
            collapsedSelection: NSRange(location: clamped, length: 0)
        )
    }

    private static func continuation(
        from session: EditorFindSession,
        resumeUTF16: Int,
        requireStartAtOrAfter minimumStart: Int
    ) -> EditorReplaceContinuation {
        let nextIndex = session.matches.firstIndex {
            $0.range.location >= minimumStart
        }
        let resolved: EditorFindSession = if let nextIndex {
            session.withCurrentOrdinal(
                nextIndex + 1,
                caretAnchorUTF16: resumeUTF16
            )
        } else {
            session.withUnresolvedCurrent(caretAnchorUTF16: resumeUTF16)
        }
        let lengthAnchor = max(0, resumeUTF16)
        return EditorReplaceContinuation(
            session: resolved,
            resumeUTF16: lengthAnchor,
            collapsedSelection: NSRange(location: lengthAnchor, length: 0)
        )
    }

    private static func mappedCollapsedOffset(
        plan: EditorReplaceBatchPlan,
        preWriteCurrentMatch: TextSearchMatch?,
        preWriteCaretUTF16: Int
    ) -> Int {
        let replacementLength = (plan.replacement as NSString).length
        if let current = preWriteCurrentMatch {
            guard let currentEnd = EditorReplacePlanning.rangeEnd(current.range) else {
                return preWriteCaretUTF16
            }
            // The current match owns its trailing edge. An adjacent next match
            // starts at that same offset but must not advance this selection.
            let precedingAndCurrent = Array(plan.differingRanges.prefix {
                $0.location < currentEnd
            })
            return EditorReplaceSourceConstruction.mapUTF16Offset(
                currentEnd,
                through: precedingAndCurrent,
                replacementUTF16Length: replacementLength
            ) ?? currentEnd
        }
        return EditorReplaceSourceConstruction.mapUTF16Offset(
            preWriteCaretUTF16,
            through: plan.differingRanges,
            replacementUTF16Length: replacementLength
        ) ?? preWriteCaretUTF16
    }
}
