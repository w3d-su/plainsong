import XCTest

/// Hosted production launch smoke. A pass means Files and its Open control are visible.
/// It is not a file-access, editing, preview, save/reopen, or device acceptance result.
final class IOSAcceptanceLaunchSmokeTests: XCTestCase {
    func testLaunchShowsFilesAndOpenControl() {
        let app = XCUIApplication()
        app.launch()
        let files = app.navigationBars["Files"]
        let open = app.buttons["plainsong.ios.browser.open"]
        let filesAppeared = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: files)
        let openAppeared = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: open)
        let result = XCTWaiter.wait(for: [filesAppeared, openAppeared], timeout: 10)
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(files.exists)
        XCTAssertTrue(open.exists)
        XCTAssertTrue(open.isEnabled)
    }
}
