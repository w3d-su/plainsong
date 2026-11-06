import UIKit

/// A preopened replacement is observed before the current document starts closing.
/// A provider notice refuses this attempt; retry opens fresh bytes under its grant.
@MainActor
final class ReplacementCandidate {
    let document: SpikeDocument
    private let expectedURL: URL
    private var opened = false
    private var changed = false

    init(document: SpikeDocument, expectedURL: URL) {
        self.document = document
        self.expectedURL = expectedURL
        document.requestRevert = { [weak self] _, completion in
            self?.changed = true
            completion?(false)
        }
        document.editingAvailability = { [weak self] enabled in
            guard let self, opened, !enabled else { return }
            changed = true
        }
    }

    var isCurrent: Bool {
        opened && !changed && document.fileURL == expectedURL &&
            !document.documentState.contains(.closed) &&
            !document.documentState.contains(.inConflict) &&
            !document.documentState.contains(.savingError) &&
            !document.documentState.contains(.editingDisabled)
    }

    func didOpen() {
        opened = true
        observeState()
    }

    func observeState() {
        guard opened else { return }
        if document.documentState.contains(.closed) ||
            document.documentState.contains(.inConflict) ||
            document.documentState.contains(.savingError) ||
            document.documentState.contains(.editingDisabled)
        {
            changed = true
        }
    }
}
