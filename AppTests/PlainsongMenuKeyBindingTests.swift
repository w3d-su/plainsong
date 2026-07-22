import Carbon
import Foundation
@testable import Plainsong
import XCTest

@MainActor
final class PlainsongMenuKeyBindingTests: XCTestCase {
    func testBindingUsesExactPhysicalShiftCommandF() {
        XCTAssertEqual(PlainsongMenuKeyBinding.ansiFKeyCode, UInt32(kVK_ANSI_F))
        XCTAssertEqual(PlainsongMenuKeyBinding.carbonModifiers, UInt32(cmdKey | shiftKey))
        XCTAssertEqual(PlainsongMenuKeyBinding.carbonModifiers & UInt32(optionKey), 0)
        XCTAssertEqual(PlainsongMenuKeyBinding.carbonModifiers & UInt32(controlKey), 0)
    }

    func testIdentifierMatchesOnlyPlainsongWorkspaceSearchHotKey() {
        let expected = EventHotKeyID(signature: 0x504C_534E, id: 1)
        let wrongSignature = EventHotKeyID(signature: 0x4F54_4845, id: 1)
        let wrongID = EventHotKeyID(signature: 0x504C_534E, id: 2)

        XCTAssertTrue(PlainsongWorkspaceSearchHotKey.matches(expected))
        XCTAssertFalse(PlainsongWorkspaceSearchHotKey.matches(wrongSignature))
        XCTAssertFalse(PlainsongWorkspaceSearchHotKey.matches(wrongID))
    }

    func testRegistrationLifecycleIsIdempotentAndRecoverable() {
        PlainsongWorkspaceSearchHotKey.tearDown()
        XCTAssertFalse(PlainsongWorkspaceSearchHotKey.isRegistered)

        PlainsongWorkspaceSearchHotKey.activate()
        XCTAssertTrue(PlainsongWorkspaceSearchHotKey.isRegistered)
        PlainsongWorkspaceSearchHotKey.activate()
        XCTAssertTrue(PlainsongWorkspaceSearchHotKey.isRegistered)

        PlainsongWorkspaceSearchHotKey.deactivate()
        XCTAssertFalse(PlainsongWorkspaceSearchHotKey.isRegistered)
        PlainsongWorkspaceSearchHotKey.deactivate()
        XCTAssertFalse(PlainsongWorkspaceSearchHotKey.isRegistered)

        PlainsongWorkspaceSearchHotKey.activate()
        XCTAssertTrue(PlainsongWorkspaceSearchHotKey.isRegistered)
        PlainsongWorkspaceSearchHotKey.tearDown()
        XCTAssertFalse(PlainsongWorkspaceSearchHotKey.isRegistered)
    }

    func testApplicationDelegateRegistersOnlyWhileActive() {
        let delegate = PlainsongApplicationDelegate()
        PlainsongWorkspaceSearchHotKey.tearDown()

        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertTrue(PlainsongWorkspaceSearchHotKey.isRegistered)

        delegate.applicationWillResignActive(Notification(name: NSApplication.willResignActiveNotification))
        XCTAssertFalse(PlainsongWorkspaceSearchHotKey.isRegistered)

        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertTrue(PlainsongWorkspaceSearchHotKey.isRegistered)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertFalse(PlainsongWorkspaceSearchHotKey.isRegistered)
    }

    func testActionTogglesSearchFilesSearchAndFocusesEachOpen() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = URL(fileURLWithPath: "/tmp/plainsong-workspace-search-key-test")
        let previousAppState = PlainsongAppServices.appState
        PlainsongAppServices.appState = appState
        defer { PlainsongAppServices.appState = previousAppState }
        let before = appState.workspaceSearchUI.focusRequestID

        XCTAssertTrue(PlainsongWorkspaceSearchKeyAction.performIfAvailable())
        XCTAssertEqual(appState.workspaceSearchUI.mode, .search)
        XCTAssertEqual(appState.workspaceSearchUI.focusRequestID, before &+ 1)

        XCTAssertTrue(PlainsongWorkspaceSearchKeyAction.performIfAvailable())
        XCTAssertEqual(appState.workspaceSearchUI.mode, .files)
        XCTAssertEqual(appState.workspaceSearchUI.focusRequestID, before &+ 1)

        XCTAssertTrue(PlainsongWorkspaceSearchKeyAction.performIfAvailable())
        XCTAssertEqual(appState.workspaceSearchUI.mode, .search)
        XCTAssertEqual(appState.workspaceSearchUI.focusRequestID, before &+ 2)
    }

    func testActionNoOpsWhenSearchUnavailable() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        let previousAppState = PlainsongAppServices.appState
        PlainsongAppServices.appState = appState
        defer { PlainsongAppServices.appState = previousAppState }
        let before = appState.workspaceSearchUI.focusRequestID

        XCTAssertFalse(PlainsongWorkspaceSearchKeyAction.performIfAvailable())
        XCTAssertEqual(appState.workspaceSearchUI.mode, .files)
        XCTAssertEqual(appState.workspaceSearchUI.focusRequestID, before)
    }

    func testHotKeyConsumesUnavailableSearchWithoutChangingState() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        let previousAppState = PlainsongAppServices.appState
        PlainsongAppServices.appState = appState
        defer { PlainsongAppServices.appState = previousAppState }

        XCTAssertEqual(PlainsongWorkspaceSearchHotKey.handlePress(), noErr)
        XCTAssertEqual(appState.workspaceSearchUI.mode, .files)
        XCTAssertEqual(appState.workspaceSearchUI.focusRequestID, 0)
    }
}
