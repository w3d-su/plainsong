import AppKit
@testable import Plainsong
import XCTest

@MainActor
final class PlainsongMenuKeyBindingTests: XCTestCase {
    func testMatchesExactShiftCommandFByKeyCode() throws {
        let event = try keyEvent(keyCode: PlainsongMenuKeyBinding.ansiFKeyCode, flags: [.command, .shift])
        XCTAssertTrue(PlainsongMenuKeyBinding.matchesFindInWorkspace(event))
    }

    func testMatchesExactShiftCommandFByCharacters() throws {
        // Non-ANSI key code still matches when charactersIgnoringModifiers is "f".
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

    func testRejectsControlCommandFFullScreenShape() throws {
        let event = try keyEvent(
            keyCode: PlainsongMenuKeyBinding.ansiFKeyCode,
            flags: [.command, .control]
        )
        XCTAssertFalse(PlainsongMenuKeyBinding.matchesFindInWorkspace(event))
    }

    func testRejectsShiftCommandP() throws {
        // P is keyCode 35 on ANSI.
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

    /// AppKit local monitor path: when a folder workspace is open, ⇧⌘F increments the
    /// Search focus token (the SwiftUI menu key-equivalent path is insufficient live).
    func testLocalMonitorFocusesWorkspaceSearchWhenFolderIsOpen() throws {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        appState.workspaceRootURL = URL(fileURLWithPath: "/tmp/plainsong-find-key-test")
        XCTAssertTrue(appState.canUseWorkspaceSearch)

        let delegate = PlainsongApplicationDelegate()
        delegate.appState = appState
        delegate.installFindInWorkspaceKeyMonitorIfNeeded()

        let before = appState.workspaceSearchUI.focusRequestID
        let event = try keyEvent(
            keyCode: PlainsongMenuKeyBinding.ansiFKeyCode,
            flags: [.command, .shift]
        )
        // Local monitors run from NSApp's event pipeline, not window.sendEvent.
        NSApp.sendEvent(event)

        XCTAssertEqual(appState.workspaceSearchUI.mode, .search)
        XCTAssertEqual(appState.workspaceSearchUI.focusRequestID, before &+ 1)
    }

    func testLocalMonitorDoesNotConsumeWhenSearchUnavailable() throws {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        XCTAssertFalse(appState.canUseWorkspaceSearch)

        let delegate = PlainsongApplicationDelegate()
        delegate.appState = appState
        delegate.installFindInWorkspaceKeyMonitorIfNeeded()

        let before = appState.workspaceSearchUI.focusRequestID
        let event = try keyEvent(
            keyCode: PlainsongMenuKeyBinding.ansiFKeyCode,
            flags: [.command, .shift]
        )
        NSApp.sendEvent(event)

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
