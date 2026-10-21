import Foundation
@testable import MarkdownCore
import XCTest

final class IOSDocumentContractTests: XCTestCase {
    func testSameVersionInDifferentOpenInstancesDoesNotAuthorizeTheSameRevision() {
        let first = IOSDocumentIdentity(rawValue: UUID())
        let reopened = IOSDocumentIdentity(rawValue: UUID())
        XCTAssertNotEqual(
            IOSDocumentRevision(documentID: first, version: 0),
            IOSDocumentRevision(documentID: reopened, version: 0)
        )
        XCTAssertNotEqual(
            IOSDocumentRevision(documentID: first, version: 0),
            IOSDocumentRevision(documentID: first, version: 1)
        )
    }

    @MainActor
    func testAcknowledgingAnOlderSavedCaptureRetainsNewerLiveSource() {
        let session = DocumentSession(text: "original")
        session.replaceText("saved capture")
        let captured = session.snapshot
        session.replaceText("newer 繁中 👩🏽‍💻")
        let live = session.snapshot
        session.rebaseSavedText(to: captured.text)
        XCTAssertEqual(session.text, live.text)
        XCTAssertEqual(session.version, live.version)
        XCTAssertTrue(session.isDirty)
    }
}
