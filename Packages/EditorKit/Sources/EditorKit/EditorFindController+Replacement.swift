import Foundation
import MarkdownCore

/// A single Replace's native write in progress. Any publication that reaches Find
/// during the write is recorded here instead of scheduling an ordinary `.edit`.
struct EditorFindReplacementArm: Equatable {
    var publication: EditorFindDocumentBinding?
}

/// Single-Replace handoff. The executor arms before its native insert and, once the
/// writer-authorized closure has returned, either admits the observed post-write
/// snapshot as one `.replacement` rescan or abandons the arm. Nothing here notifies
/// session observers while the write is still running.
extension EditorFindController {
    func armReplacementPublication() {
        armedReplacementPublication = EditorFindReplacementArm()
    }

    /// Called by `documentTextDidChange` for a changed binding. Returns `true` when the
    /// publication belongs to an armed write and was only recorded.
    func recordArmedReplacementPublication(text: String, revision: UInt64) -> Bool {
        guard armedReplacementPublication != nil else { return false }
        recordedReplacementPublicationCount &+= 1
        armedReplacementPublication?.publication = EditorFindDocumentBinding(
            identity: documentBinding.identity,
            text: text,
            revision: revision
        )
        return true
    }

    /// The executor verified that `text` at `revision` is exactly the planned post-write
    /// source. That revision is consumed once, by one `afterOneReplace` rescan; a recorded
    /// publication of the same write is superseded by it and never becomes an `.edit`.
    ///
    /// Returns `false` without effect when the arm did not survive the write: a rebind or
    /// `clearForNoDocument` during it already moved Find to newer document state.
    func admitReplacementPublication(
        plan: EditorReplaceOneMatchPlan,
        text: String,
        revision: UInt64
    ) -> Bool {
        guard armedReplacementPublication != nil else { return false }
        armedReplacementPublication = nil
        startReplacementGeneration(work: .one(plan), text: text, revision: revision)
        return true
    }

    func admitBatchReplacementPublication(
        plan: MarkdownCore.EditorReplaceBatchPlan,
        text: String,
        revision: UInt64,
        preWriteCurrentMatch: TextSearchMatch?,
        preWriteCaretUTF16: Int,
        mappedAnchorUTF16: Int
    ) -> Bool {
        guard armedReplacementPublication != nil else { return false }
        armedReplacementPublication = nil
        startReplacementGeneration(
            work: .batch(plan, preWriteCurrentMatch, preWriteCaretUTF16, mappedAnchorUTF16),
            text: text, revision: revision
        )
        return true
    }

    /// The write did not produce the planned source. A publication recorded during it is
    /// handed back as an ordinary edit (counter-only, no navigation).
    func abandonReplacementPublication() {
        guard let arm = armedReplacementPublication else { return }
        armedReplacementPublication = nil
        if let publication = arm.publication {
            documentTextDidChange(text: publication.text, revision: publication.revision)
        }
    }

    /// Literal-identical continuation. Installs the retained session without a rescan.
    func installUnchangedContinuation(_ continuation: EditorReplaceContinuation) {
        installContinuation(continuation, stepsRecordedFor: nil)
    }
}
