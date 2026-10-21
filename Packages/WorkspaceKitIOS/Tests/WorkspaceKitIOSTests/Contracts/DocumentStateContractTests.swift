import Foundation
import WorkspaceKitIOS
import XCTest

final class DocumentStateContractTests: XCTestCase {
    func testConflictUnavailableAndClosedStatesFenceWritingAndRetainGeneration() {
        let states: [IOSDocumentState] = [
            .opening(accessGeneration: 11),
            .conflict(accessGeneration: 11, recovery: nil),
            .unavailable(accessGeneration: 11, reason: .access(.offline)),
            .closed(accessGeneration: 11),
        ]
        for state in states {
            XCTAssertFalse(state.canWrite)
            XCTAssertEqual(state.accessGeneration, 11)
        }
        XCTAssertFalse(IOSDocumentState.ready(canWrite: false, accessGeneration: 12).canWrite)
        XCTAssertTrue(IOSDocumentState.saving(canWrite: true, accessGeneration: 12, operationID: UUID()).canWrite)
    }
}
