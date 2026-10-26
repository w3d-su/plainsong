import MarkdownCore

/// Live store authority for a proposal that an editor may have deferred earlier.
public enum IOSDocumentReloadAdmission: Equatable, Sendable {
    case installable
    case held
    case refused(IOSDocumentReloadRefusal)
}

/// An implementation capability in addition to the frozen document-store facade.
/// A deferred proposal must recheck its owner immediately before native installation.
@MainActor
public protocol IOSDocumentReloadAdmitting: AnyObject {
    func reloadAdmission(for proposal: IOSDocumentReloadProposal) -> IOSDocumentReloadAdmission
}

extension IOSUIDocumentStore: IOSDocumentReloadAdmitting {
    public func reloadAdmission(for proposal: IOSDocumentReloadProposal) -> IOSDocumentReloadAdmission {
        guard let entry = byIdentity[proposal.capturedRevision.documentID],
              !entry.closed, !entry.superseded,
              entry.pendingProposal?.operationID == proposal.operationID
        else { return .refused(.documentChanged) }
        guard guardCurrentAuthority(entry, generation: proposal.accessGeneration) else {
            return .refused(.accessChanged)
        }
        guard entry.session?.version == proposal.capturedRevision.version else {
            return .refused(.sourceChanged)
        }
        if entry.isClosing || entry.isRetiring || entry.portClosed {
            return .held
        }
        return .installable
    }
}
