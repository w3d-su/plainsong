@testable import Plainsong
import XCTest

/// The perf harness runs this bundle in Release. The gate that keeps a test run off the
/// owner's last-opened file and durable recovery stores has to hold there too.
@MainActor
final class XCTestIsolationGateTests: XCTestCase {
    func testATestRunIsRecognisedAsOneInEveryConfiguration() {
        XCTAssertTrue(AppState.isRunningUnderXCTest)
    }
}
