import AppKit
@testable import Plainsong
import XCTest

@MainActor
final class PlainsongMenuKeyBindingTests: XCTestCase {
    override func tearDown() {
        PlainsongAppServices.appState = nil
        super.tearDown()
    }

    func testMatchesExactShiftCommandFByKeyCode() throws {
        let event = try keyEvent(keyCode: PlainsongMenuKeyBinding.ansiFKeyCode, flags: [.command, .shift])
        XCTAssertTrue(PlainsongMenuKeyBinding.matchesFindInWorkspace(event))
    }

    func testMatchesExactShiftCommandFByCharacters() throws {
        let event = try keyEvent(keyCode: 0, flags: [.command, .shift], characters: "f")
        XCTAssertTrue(PlainsongMenuKeyBinding.matchesFindInWorkspace(event))
    }

    func testRejectsCommandOnlyF() throws {
        let event = try keyEvent(keyCode: PlainsongMenuKeyBinding.ansiFKeyCode, flags: [.command])
        XCTAssertFalse(PlainsongMenuKeyBinding.matchesFindInWorkspace(event))
    }

    func testRejectsOptionCommandFFormatTableShape() throws {
        let event = try keyEvent(
            keyCode: PlainsongMenuKeyBinding.ansiFKeyCode,
            flags: [.command, .option]
        )
        XCTAssertFalse(PlainsongMenuKeyBinding.matchesFindInWorkspace(event))
    }

    func testAllowsSpuriousOptionWithShiftCommandF() throws {
        let event = try keyEvent(
            keyCode: PlainsongMenuKeyBinding.ansiFKeyCode,
            flags: [.command, .shift, .option]
        )
        XCTAssertTrue(PlainsongMenuKeyBinding.matchesFindInWorkspace(event))
    }

    func testRejectsControlCommandFFullScreenShape() throws {
        let event = try keyEvent(
            keyCode: PlainsongMenuKeyBinding.ansiFKeyCode,
            flags: [.command, .control]
        )
        XCTAssertFalse(PlainsongMenuKeyBinding.matchesFindInWorkspace(event))
    }

    func testRejectsControlShiftCommandF() throws {
        let event = try keyEvent(
            keyCode: PlainsongMenuKeyBinding.ansiFKeyCode,
            flags: [.command, .shift, .control]
        )
        XCTAssertFalse(PlainsongMenuKeyBinding.matchesFindInWorkspace(event))
    }

    func testRejectsShiftCommandP() throws {
        let event = try keyEvent(keyCode: 35, flags: [.command, .shift], characters: "p")
        XCTAssertFalse(PlainsongMenuKeyBinding.matchesFindInWorkspace(event))
    }

    func testIgnoresCapsLockAlongsideShiftCommandF() throws {
        let event = try keyEvent(
            keyCode: PlainsongMenuKeyBinding.ansiFKeyCode,
            flags: [.command, .shift, .capsLock]
        )
        XCTAssertTrue(PlainsongMenuKeyBinding.matchesFindInWorkspace(event))
    }

    func testActionFocusesSearchWhenFolderIsOpen() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = URL(fileURLWithPath: "/tmp/plainsong-find-key-test")
        PlainsongAppServices.appState = appState
        let before = appState.workspaceSearchUI.focusRequestID

        XCTAssertTrue(PlainsongFindInWorkspaceKeyAction.performIfAvailable())
        XCTAssertEqual(appState.workspaceSearchUI.mode, .search)
        XCTAssertEqual(appState.workspaceSearchUI.focusRequestID, before &+ 1)
    }

    func testActionNoOpsWhenSearchUnavailable() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        PlainsongAppServices.appState = appState
        let before = appState.workspaceSearchUI.focusRequestID

        XCTAssertFalse(PlainsongFindInWorkspaceKeyAction.performIfAvailable())
        XCTAssertEqual(appState.workspaceSearchUI.mode, .files)
        XCTAssertEqual(appState.workspaceSearchUI.focusRequestID, before)
    }

    // MARK: - Helpers

    private func keyEvent(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        characters: String = "f"
    ) throws -> NSEvent {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
        return try XCTUnwrap(event)
    }
}
