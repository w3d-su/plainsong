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

    func testRecoveredDraftsOpensAndDismissesFromProductionFiles() {
        let app = XCUIApplication()
        app.launch()
        let recovery = app.buttons["plainsong.ios.recovery.open"]
        let entryAppeared = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: recovery)
        XCTAssertEqual(XCTWaiter.wait(for: [entryAppeared], timeout: 10), .completed)
        XCTAssertTrue(recovery.isEnabled)
        recovery.tap()
        let drafts = app.navigationBars["Recovered Drafts"]
        let draftsAppeared = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: drafts)
        XCTAssertEqual(XCTWaiter.wait(for: [draftsAppeared], timeout: 10), .completed)
        drafts.buttons["Done"].tap()
        let files = app.navigationBars["Files"]
        let filesReappeared = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: files)
        XCTAssertEqual(XCTWaiter.wait(for: [filesReappeared], timeout: 10), .completed)
    }

    func testRecentFilesOpensAndDismissesFromProductionFiles() {
        let app = XCUIApplication()
        app.launch()
        let recent = app.buttons["plainsong.ios.browser.recents"]
        let entryAppeared = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: recent)
        XCTAssertEqual(XCTWaiter.wait(for: [entryAppeared], timeout: 10), .completed)
        XCTAssertTrue(recent.isEnabled)
        recent.tap()
        let list = app.navigationBars["Recent Files and Folders"]
        let listAppeared = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: list)
        XCTAssertEqual(XCTWaiter.wait(for: [listAppeared], timeout: 10), .completed)
        list.buttons["Done"].tap()
        let files = app.navigationBars["Files"]
        let filesReappeared = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: files)
        XCTAssertEqual(XCTWaiter.wait(for: [filesReappeared], timeout: 10), .completed)
    }
}
