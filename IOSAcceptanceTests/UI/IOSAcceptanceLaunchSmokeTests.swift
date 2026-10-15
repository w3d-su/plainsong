import XCTest

/// Hosted smoke for lane 12. A pass means the unavailable scaffold is visible.
/// It is not a writing, preview, save, or device acceptance result.
final class IOSAcceptanceLaunchSmokeTests: XCTestCase {
    func testLaunchShowsUnavailableScaffold() {
        let app = XCUIApplication()
        app.launch()
        let scaffold = app.staticTexts[
            "Development scaffold. Editing and file access await device validation and providers."
        ]
        let appeared = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: scaffold)
        let result = XCTWaiter.wait(for: [appeared], timeout: 10)
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(scaffold.exists)
    }
}
