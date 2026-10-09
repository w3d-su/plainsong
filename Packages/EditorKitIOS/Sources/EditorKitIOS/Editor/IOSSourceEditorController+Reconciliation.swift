import MarkdownCore
import UIKit

extension IOSSourceEditorController {
    public func installExternalReload(_ proposal: IOSDocumentReloadProposal) -> IOSDocumentReloadOutcome {
        guard let installation = reloadInstallation(matching: proposal) else {
            return reloadRefusal(for: proposal)
        }
        if textView.markedTextRange != nil || isMutating {
            return .deferred
        }
        if ExactSourceFragment.matches(proposal.text, plainText()) {
            return .installed(currentRevision(installation))
        }
        return installChangedReload(proposal, installation: installation)
    }

    private func reloadInstallation(
        matching proposal: IOSDocumentReloadProposal
    ) -> IOSSourceEditorDocumentBinding? {
        guard isHostAlive, textView.isTextKit2, let installation else { return nil }
        guard proposal.capturedRevision.documentID == installation.identity else { return nil }
        guard proposal.capturedRevision.version == installation.session.version else { return nil }
        guard proposal.accessGeneration == installation.accessGeneration else { return nil }
        guard ExactSourceFragment.matches(plainText(), installation.session.text) else { return nil }
        return installation
    }

    private func reloadRefusal(for proposal: IOSDocumentReloadProposal) -> IOSDocumentReloadOutcome {
        guard isHostAlive, textView.isTextKit2, let installation else { return .refused(.unavailable) }
        if proposal.capturedRevision.documentID != installation.identity {
            return .refused(.documentChanged)
        }
        if proposal.accessGeneration != installation.accessGeneration {
            return .refused(.accessChanged)
        }
        return .refused(.sourceChanged)
    }

    private func installChangedReload(
        _ proposal: IOSDocumentReloadProposal,
        installation: IOSSourceEditorDocumentBinding
    ) -> IOSDocumentReloadOutcome {
        isReconciling = true
        defer { isReconciling = false }
        let selected = textView.selectedRange
        guard IOSNativeTextMutation.replaceBufferWithoutUndo(proposal.text, in: textView) else {
            return .refused(.unavailable)
        }
        // Groups created before this replacement address the buffer that no longer exists.
        // Hiding the view does not come through this path, so that undo stack stays.
        textView.undoManager?.removeAllActions()
        installation.session.replaceTextFromAuthorizedEditor(proposal.text, refreshStatistics: false)
        installation.session.applyStatistics(proposal.statistics)
        isAdjustingSelection = true
        textView.selectedRange = IOSTextRanges.clamped(selected, length: textView.textStorage.length)
        isAdjustingSelection = false
        selectionGeneration &+= 1
        lastSelection = textView.selectedRange
        raisePresentationFloor()
        IOSHighlightPresenter.clearOwnedAttributes(
            in: NSRange(location: 0, length: textView.textStorage.length),
            of: textView
        )
        scheduleHighlight()
        emitSnapshot()
        return .installed(currentRevision(installation))
    }
}
