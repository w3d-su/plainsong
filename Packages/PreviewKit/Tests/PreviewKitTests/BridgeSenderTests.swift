@testable import PreviewKit
import XCTest

final class BridgeSenderTests: XCTestCase {
    func testOnlyTheOwnMainFrameIsAccepted() {
        let owner = NSObject()
        let other = NSObject()

        XCTAssertTrue(PreviewController.acceptsBridgeSender(isMainFrame: true, sender: owner, owner: owner))
        XCTAssertFalse(PreviewController.acceptsBridgeSender(isMainFrame: false, sender: owner, owner: owner))
        XCTAssertFalse(PreviewController.acceptsBridgeSender(isMainFrame: true, sender: other, owner: owner))
        XCTAssertFalse(PreviewController.acceptsBridgeSender(isMainFrame: true, sender: nil, owner: owner))
    }
}
