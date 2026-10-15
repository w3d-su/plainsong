import MarkdownCore
@testable import PlainsongIOS
import XCTest

final class OpenDocumentAdmissionTests: XCTestCase {
    func testFirstAdmissionInstallsOneWriter() {
        var admission = IOSOpenDocumentAdmission()
        let documentID = IOSDocumentIdentity(rawValue: UUID())

        guard case let .success(ticket) = admission.begin(documentID: documentID) else {
            return XCTFail("The first admission must install one writer")
        }

        XCTAssertEqual(ticket.documentID, documentID)
        XCTAssertEqual(admission.active, ticket)
    }

    func testSecondIdentityIsRefusedWhileTheFirstTicketIsActive() {
        var admission = IOSOpenDocumentAdmission()
        let first = IOSDocumentIdentity(rawValue: UUID())
        let second = IOSDocumentIdentity(rawValue: UUID())
        guard case let .success(ticket) = admission.begin(documentID: first) else {
            return XCTFail("The first admission must install one writer")
        }

        guard case let .failure(refusal) = admission.begin(documentID: second) else {
            return XCTFail("A second identity must not open another writer")
        }

        XCTAssertEqual(refusal, .writerAlreadyActive(ticket))
        XCTAssertEqual(admission.active, ticket)
    }

    func testSameIdentityDoesNotOpenASecondWriter() {
        var admission = IOSOpenDocumentAdmission()
        let documentID = IOSDocumentIdentity(rawValue: UUID())
        guard case let .success(ticket) = admission.begin(documentID: documentID) else {
            return XCTFail("The first admission must install one writer")
        }

        guard case let .failure(refusal) = admission.begin(documentID: documentID) else {
            return XCTFail("The same identity must not open a second writer")
        }

        XCTAssertEqual(refusal, .writerAlreadyActive(ticket))
        XCTAssertEqual(admission.active?.documentID, documentID)
    }

    func testEndingAnotherTicketDoesNotReleaseTheActiveWriter() {
        var admission = IOSOpenDocumentAdmission()
        let documentID = IOSDocumentIdentity(rawValue: UUID())
        guard case let .success(ticket) = admission.begin(documentID: documentID) else {
            return XCTFail("The first admission must install one writer")
        }
        let other = IOSOpenDocumentAdmission.Ticket(
            documentID: IOSDocumentIdentity(rawValue: UUID())
        )

        admission.end(other)

        XCTAssertEqual(admission.active, ticket)
        guard case .failure = admission.begin(documentID: other.documentID) else {
            return XCTFail("A foreign end must leave the active writer in place")
        }
    }

    func testEndingTheActiveTicketAllowsTheNextDocument() {
        var admission = IOSOpenDocumentAdmission()
        let first = IOSDocumentIdentity(rawValue: UUID())
        let second = IOSDocumentIdentity(rawValue: UUID())
        guard case let .success(ticket) = admission.begin(documentID: first) else {
            return XCTFail("The first admission must install one writer")
        }

        admission.end(ticket)
        XCTAssertNil(admission.active)

        guard case let .success(next) = admission.begin(documentID: second) else {
            return XCTFail("Ending the active ticket must allow the next document")
        }
        XCTAssertEqual(next.documentID, second)
        XCTAssertEqual(admission.active, next)
    }
}
