import Foundation

extension IOSUIDocumentStore {
    /// Transient observation/lifecycle barriers never imply a clean document.
    func writeBarrier(_ entry: IOSDocumentEntry, allowsClosing: Bool = false) -> Bool {
        entry.fenced || entry.externalToken != nil || entry.pendingProposal != nil
            || entry.isRetiring || entry.portClosed || (entry.isClosing && !allowsClosing)
    }

    func refreshWritableState(_ entry: IOSDocumentEntry) {
        guard !entry.closed, !entry.superseded, !entry.fenced else { return }
        let writable = entry.allowsProviderWrite && !entry.lease.isReleased && !writeBarrier(entry)
        if case let .saving(_, generation, operationID) = entry.state, entry.inFlightText != nil {
            setState(.saving(canWrite: writable, accessGeneration: generation, operationID: operationID), entry: entry)
        } else {
            setState(.ready(canWrite: writable, accessGeneration: entry.accessGeneration), entry: entry)
        }
    }
}
