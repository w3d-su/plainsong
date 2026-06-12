@testable import EditorKit
import XCTest

final class EditorKitTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertFalse(EditorKitInfo.version.isEmpty)
    }
}
