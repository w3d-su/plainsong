@testable import WorkspaceKit
import XCTest

final class WorkspaceKitTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertFalse(WorkspaceKitInfo.version.isEmpty)
    }
}
