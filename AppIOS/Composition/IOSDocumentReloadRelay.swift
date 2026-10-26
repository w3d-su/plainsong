import EditorKitIOS
import Foundation
import MarkdownCore
import WorkspaceKitIOS

/// Relays external reads through the installed native editor. Save acknowledgements
/// never enter this path. The store remains the only owner of the saved baseline.
@MainActor
final class IOSDocumentReloadRelay {
    private struct Installation: Equatable {
        let documentID: IOSDocumentIdentity
        let bindingID: UUID
        let accessGeneration: UInt64
    }

    private struct Pending {
        let proposal: IOSDocumentReloadProposal
        let epoch: UInt64
    }

    private let documents: any IOSDocumentStore
    private let editor: any IOSSourceEditorBinding
    private var installation: Installation?
    private var epoch: UInt64 = 0
    private var pending: Pending?
    // Operation IDs are opaque, so evicting an arbitrary old ID would authorize
    // replay after a same-document rebind. Keep tombstones for this relay's lifetime.
    private var retiredOperations: Set<UUID> = []
    private var documentObservation: (any IOSObservation)?
    private var editorObservation: (any IOSObservation)?
    private var isProcessing = false
    private var activeOperationID: UUID?

    init(documents: any IOSDocumentStore, editor: any IOSSourceEditorBinding) {
        self.documents = documents
        self.editor = editor
    }

    /// Call after attaching the editor, and again after changing its access generation.
    /// A new binding always starts a new callback lifetime, even for the same document.
    func attach(documentID: IOSDocumentIdentity, bindingID: UUID, accessGeneration: UInt64) {
        let next = Installation(
            documentID: documentID, bindingID: bindingID, accessGeneration: accessGeneration
        )
        guard installation != next else { return }
        detach()
        installation = next
        let capturedEpoch = epoch
        let documentToken = documents.observe { [weak self] event in
            self?.receive(event, epoch: capturedEpoch)
        }
        guard epoch == capturedEpoch else {
            documentToken.cancel()
            return
        }
        documentObservation = documentToken
        let editorToken = editor.observe { [weak self] event in
            self?.receive(event, epoch: capturedEpoch)
        }
        guard epoch == capturedEpoch else {
            editorToken.cancel()
            return
        }
        editorObservation = editorToken
    }

    func detach() {
        epoch &+= 1
        installation = nil
        if let pending {
            retiredOperations.insert(pending.proposal.operationID)
        }
        if let activeOperationID {
            retiredOperations.insert(activeOperationID)
        }
        pending = nil
        let oldDocumentObservation = documentObservation
        let oldEditorObservation = editorObservation
        documentObservation = nil
        editorObservation = nil
        oldDocumentObservation?.cancel()
        oldEditorObservation?.cancel()
    }

    private func receive(_ event: IOSDocumentEvent, epoch capturedEpoch: UInt64) {
        guard capturedEpoch == epoch, let installation, case let .externalReloadRequested(proposal) = event,
              proposal.capturedRevision.documentID == installation.documentID,
              proposal.accessGeneration == installation.accessGeneration,
              proposal.operationID != activeOperationID,
              !retiredOperations.contains(proposal.operationID)
        else { return }
        if let pending, pending.proposal.operationID != proposal.operationID {
            // The store superseded its earlier read; it must not be retried later.
            retiredOperations.insert(pending.proposal.operationID)
        }
        pending = Pending(proposal: proposal, epoch: capturedEpoch)
        drain()
    }

    private func receive(_ event: IOSSourceEditorEvent, epoch capturedEpoch: UInt64) {
        guard capturedEpoch == epoch, let installation else { return }
        switch event {
        case let .snapshotChanged(snapshot):
            guard snapshot.bindingID == installation.bindingID,
                  snapshot.revision.documentID == installation.documentID
            else { return }
            // Marked-text callbacks are observations, never permission to cancel it.
            guard !snapshot.hasMarkedText else { return }
            drain()
        case let .detached(documentID, bindingID):
            if documentID == installation.documentID, bindingID == installation.bindingID {
                detach()
            }
        }
    }

    private func drain() {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        while let candidate = pending {
            pending = nil
            guard candidate.epoch == epoch, let installation,
                  !retiredOperations.contains(candidate.proposal.operationID)
            else { continue }
            activeOperationID = candidate.proposal.operationID
            defer { activeOperationID = nil }
            let snapshot = editor.captureSnapshot()
            guard candidate.epoch == epoch else { continue }
            if let pending, pending.proposal.operationID != candidate.proposal.operationID {
                retiredOperations.insert(candidate.proposal.operationID)
                continue
            }
            let outcome: IOSDocumentReloadOutcome = if let refusal = refusal(
                for: candidate.proposal,
                snapshot: snapshot,
                installation: installation
            ) {
                .refused(refusal)
            } else {
                editor.installExternalReload(candidate.proposal)
            }
            // Native installation can synchronously publish events. A replaced binding
            // must not acknowledge through the newer installation's callback lifetime.
            guard candidate.epoch == epoch else { continue }
            if case .deferred = outcome {
                if pending == nil {
                    pending = candidate
                }
            } else {
                retiredOperations.insert(candidate.proposal.operationID)
            }
            // This synchronous pair deliberately has no Task or await between calls.
            documents.acknowledgeExternalReload(operationID: candidate.proposal.operationID, outcome: outcome)
            if case .deferred = outcome, pending?.proposal.operationID == candidate.proposal.operationID {
                // Retry only on a later editor event, not our own acknowledgement.
                break
            }
        }
    }

    private func refusal(
        for proposal: IOSDocumentReloadProposal,
        snapshot: IOSSourceEditorSnapshot?,
        installation: Installation
    ) -> IOSDocumentReloadRefusal? {
        guard let snapshot else { return .unavailable }
        guard snapshot.bindingID == installation.bindingID,
              snapshot.revision.documentID == installation.documentID
        else { return .documentChanged }
        guard snapshot.accessGeneration == installation.accessGeneration else { return .accessChanged }
        guard snapshot.revision == proposal.capturedRevision else { return .sourceChanged }
        return nil
    }
}
