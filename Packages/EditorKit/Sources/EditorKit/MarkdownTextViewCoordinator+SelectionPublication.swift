import Foundation

@MainActor
extension MarkdownTextViewCoordinator {
    var isInsideRepresentableUpdate: Bool {
        representableUpdateDepth > 0
    }

    func beginRepresentableUpdate() {
        representableUpdateDepth += 1
    }

    func endRepresentableUpdate() {
        precondition(representableUpdateDepth > 0)
        representableUpdateDepth -= 1
    }

    func invalidateDeferredSelectionPublication() {
        selectionPublicationGeneration &+= 1
    }

    /// A navigation applied from `updateNSView` must publish its SwiftUI selection binding
    /// on the next main turn. The native selection is already exact; the generation fence
    /// prevents that deferred receipt from overwriting newer user selection.
    func publishAppliedSelection(_ range: NSRange) {
        publishSelection(range)
    }

    func publishObservedSelection(_ range: NSRange) {
        publishSelection(range)
    }

    private func publishSelection(_ range: NSRange) {
        selectionPublicationGeneration &+= 1
        let publicationGeneration = selectionPublicationGeneration
        let documentIdentity = currentDocumentIdentity
        let installedCandidateGeneration = installedDocument.installedCandidateGeneration
        guard isInsideRepresentableUpdate else {
            selection = range
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  selectionPublicationGeneration == publicationGeneration,
                  currentDocumentIdentity == documentIdentity,
                  installedDocument.installedCandidateGeneration == installedCandidateGeneration
            else {
                return
            }
            selection = range
        }
    }
}
