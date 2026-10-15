import Foundation
import MarkdownCore

/// One scene admits one document writer. A second call is refused until that
/// ticket ends. URL, inode, and document-identifier equality are not inputs.
/// This value does not open a file, create a session, or install a provider.
struct IOSOpenDocumentAdmission: Equatable {
    struct Ticket: Equatable {
        let documentID: IOSDocumentIdentity
    }

    enum Refusal: Equatable, Error {
        case writerAlreadyActive(Ticket)
    }

    private(set) var active: Ticket?

    mutating func begin(documentID: IOSDocumentIdentity) -> Result<Ticket, Refusal> {
        if let active {
            return .failure(.writerAlreadyActive(active))
        }
        let ticket = Ticket(documentID: documentID)
        active = ticket
        return .success(ticket)
    }

    mutating func end(_ ticket: Ticket) {
        guard active == ticket else { return }
        active = nil
    }
}
