import Foundation
@testable import PlainsongIOS
import WorkspaceKitIOS
import XCTest

final class IOSOperationFeedbackTests: XCTestCase {
    func testRetainedCloseExplainsProviderOrExternalChangesWithoutInventingUnsavedEdits() {
        let message = IOSOperationFeedback.message(for: IOSDocumentFailure.closeFailed)
        XCTAssertTrue(message.contains("still open"))
        XCTAssertTrue(message.contains("provider or an external file change"))
        XCTAssertFalse(message.contains("Resolve the current document's changes"))
    }

    func testProviderFailuresUseActionableCopyInsteadOfEnumDescriptions() {
        XCTAssertEqual(
            IOSOperationFeedback.message(for: IOSDocumentFailure.access(.permissionDenied)),
            "Access is no longer available. Choose the file or folder again."
        )
        XCTAssertTrue(IOSOperationFeedback.message(for: IOSWorkspaceFailure.alreadyExists)
            .contains("Choose another name"))
        XCTAssertTrue(IOSOperationFeedback.message(for: IOSDocumentFailure.saveFailed)
            .contains("current text is retained"))
        XCTAssertFalse(IOSOperationFeedback.message(for: IOSDocumentFailure.saveFailed).contains("saveFailed"))
    }
}
