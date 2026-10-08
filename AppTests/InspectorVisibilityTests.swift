import AppKit
@testable import Plainsong
import XCTest

@MainActor
final class InspectorVisibilityTests: XCTestCase {
    func testAutomaticCollapseRetainsIntentAndRestoresOnlyRequestedInspector() {
        let visibility = InspectorVisibility(userIntent: true)
        visibility.updateLayout(availableWidth: 600, inspectorWidth: 280, contentMinimum: 521, hasDocument: true)
        XCTAssertFalse(visibility.isPresented)
        XCTAssertTrue(visibility.userIntent)
        visibility.updateLayout(availableWidth: 1000, inspectorWidth: 280, contentMinimum: 521, hasDocument: true)
        XCTAssertTrue(visibility.isPresented)
        visibility.toggle()
        XCTAssertFalse(visibility.userIntent)
        visibility.updateLayout(availableWidth: 600, inspectorWidth: 280, contentMinimum: 521, hasDocument: true)
        visibility.updateLayout(availableWidth: 1000, inspectorWidth: 280, contentMinimum: 521, hasDocument: true)
        XCTAssertFalse(visibility.isPresented)
    }

    func testRestoredHiddenIntentStartsHiddenAndEmptyDocumentDisablesMenu() {
        let visibility = InspectorVisibility(userIntent: false)
        XCTAssertFalse(visibility.userIntent)
        XCTAssertFalse(visibility.isPresented)
        visibility.updateLayout(availableWidth: 1280, inspectorWidth: 280, contentMinimum: 260, hasDocument: false)
        InspectorMenuState.shared.windowBecameKey(visibility)
        XCTAssertNil(InspectorMenuState.shared.isKeyWindowInspectorPresented)
        InspectorMenuState.shared.toggleKeyWindowInspector()
        XCTAssertFalse(visibility.userIntent)
        InspectorMenuState.shared.windowResignedKey(visibility)
    }

    func testCloseAndResignSynchronouslyClearInspectorMenu() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let visibility = InspectorVisibility(userIntent: true)
        visibility.updateLayout(availableWidth: 1000, inspectorWidth: 280, contentMinimum: 260, hasDocument: true)
        visibility.attach(to: window)
        for notification in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            InspectorMenuState.shared.windowBecameKey(visibility)
            XCTAssertEqual(InspectorMenuState.shared.isKeyWindowInspectorPresented, true)
            NotificationCenter.default.post(name: notification, object: window)
            XCTAssertNil(InspectorMenuState.shared.isKeyWindowInspectorPresented)
        }
        window.close()
    }

    func testShowWithoutRoomRetainsIntentWithoutSqueezingContent() {
        let visibility = InspectorVisibility(userIntent: false)
        visibility.updateLayout(availableWidth: 600, inspectorWidth: 360, contentMinimum: 521, hasDocument: true)
        visibility.toggle()
        XCTAssertTrue(visibility.userIntent)
        XCTAssertFalse(visibility.isPresented)
        visibility.updateLayout(availableWidth: 886, inspectorWidth: 360, contentMinimum: 521, hasDocument: true)
        XCTAssertTrue(visibility.isPresented)
    }
}
