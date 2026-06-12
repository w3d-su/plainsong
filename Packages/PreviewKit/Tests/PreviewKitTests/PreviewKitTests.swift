@testable import PreviewKit
import XCTest

final class PreviewKitTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertFalse(PreviewKitInfo.version.isEmpty)
    }
}
