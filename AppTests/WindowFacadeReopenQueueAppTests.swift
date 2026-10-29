import AppKit
@testable import Plainsong
import XCTest

/// A File command or Quit refusal whose scene never attaches must be retryable, and the
/// only workspace window comes forward when Settings is key.
@MainActor
final class WindowFacadeReopenQueueAppTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        KeyWindowRouter.shared.resetForTesting()
        suiteName = "WindowFacadeReopenQueue-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        for window in windows {
            window.orderOut(nil)
        }
        windows = []
        KeyWindowRouter.shared.resetForTesting()
        WindowOpenAdmission.resetForTesting()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testSingleWorkspaceWindowFileCommandComesForwardWhenSettingsIsKey() {
        let owner = makePrimary()
        _ = WindowFacadeHolder(owner: owner)
        KeyWindowRouter.shared.attach(makeWindow(), to: owner)
        KeyWindowRouter.shared.testingUsesKeyWindowOverride = true
        KeyWindowRouter.shared.testingKeyWindow = makeWindow()
        XCTAssertNil(KeyWindowRouter.shared.menuTarget(defaultFacade: nil))

        var ran = false
        WorkspaceSceneReopener.shared.performFileCommand(openScene: {
            XCTFail("the only workspace window is already attached")
        }, action: { facade in
            XCTAssertTrue(facade === owner)
            ran = true
        })
        XCTAssertTrue(ran)
        XCTAssertTrue(KeyWindowRouter.shared.focusedWindowState === owner.windowState)
    }

    func testQuitRefusalStaysQueuedBesideTheLatestFileCommand() {
        let owner = makePrimary()
        _ = WindowFacadeHolder(owner: owner)
        KeyWindowRouter.shared.attach(makeWindow(), to: owner)
        KeyWindowRouter.shared.closeFacade(owner)
        var opened = 0
        WorkspaceSceneReopener.shared.installOpenScene { opened += 1 }
        owner.presentOnHome(ReopenQueueProbeError(), title: "Could Not Quit")
        var ran = false
        WorkspaceSceneReopener.shared.performFileCommand(openScene: { opened += 1 }, action: { facade in
            XCTAssertTrue(facade === owner)
            ran = true
        })
        XCTAssertEqual(opened, 1, "the file command joins the scene the refusal already opened")

        _ = WindowFacadeHolder(owner: owner)
        KeyWindowRouter.shared.attach(makeWindow(), to: owner)
        XCTAssertTrue(ran)
        XCTAssertEqual(owner.presentedError?.title, "Could Not Quit")
    }

    func testSilentSceneOpenExpiresSoTheNextCommandOpensAgain() {
        let owner = makePrimary()
        _ = WindowFacadeHolder(owner: owner)
        KeyWindowRouter.shared.attach(makeWindow(), to: owner)
        KeyWindowRouter.shared.closeFacade(owner)
        var opened = 0
        var ran: [Int] = []
        WorkspaceSceneReopener.shared.performFileCommand(openScene: { opened += 1 }, action: { _ in
            ran.append(1)
        })
        XCTAssertEqual(opened, 1)
        WorkspaceSceneReopener.shared.expireOpeningForTesting()

        WorkspaceSceneReopener.shared.performFileCommand(openScene: { opened += 1 }, action: { _ in
            ran.append(2)
        })
        XCTAssertEqual(opened, 2, "a command after a silent open asks for the scene again")
        _ = WindowFacadeHolder(owner: owner)
        KeyWindowRouter.shared.attach(makeWindow(), to: owner)
        XCTAssertEqual(ran, [2], "the command from the silent open does not replay")
    }

    func testExpiredReopenDropsAStaleQuitRefusal() {
        let owner = makePrimary()
        _ = WindowFacadeHolder(owner: owner)
        KeyWindowRouter.shared.attach(makeWindow(), to: owner)
        KeyWindowRouter.shared.closeFacade(owner)
        var opened = 0
        WorkspaceSceneReopener.shared.installOpenScene { opened += 1 }
        owner.presentOnHome(ReopenQueueProbeError(), title: "Could Not Quit")
        XCTAssertEqual(opened, 1)
        WorkspaceSceneReopener.shared.expireOpeningForTesting()

        _ = WindowFacadeHolder(owner: owner)
        KeyWindowRouter.shared.attach(makeWindow(), to: owner)
        XCTAssertNil(owner.presentedError, "a quit refusal from a silent open does not replay")
    }

    func testLaunchWithoutASceneOpensForACommandThatWasWaiting() {
        let owner = makePrimary()
        WorkspaceSceneReopener.shared.remember(owner)
        XCTAssertFalse(KeyWindowRouter.shared.isOwnerClaimed(owner))
        var opened = 0
        WorkspaceSceneReopener.shared.performFileCommand(openScene: { opened += 1 }, action: { _ in })
        XCTAssertEqual(opened, 0, "SwiftUI is already opening the launch scene")
        WorkspaceSceneReopener.shared.noteLaunchSettled()
        XCTAssertEqual(opened, 1, "launch produced no scene, so the waiting command opens one")
        WorkspaceSceneReopener.shared.performFileCommand(openScene: { opened += 1 }, action: { _ in })
        XCTAssertEqual(opened, 1, "the follow-up command waits for that open")
    }

    func testLaunchWaitsForTheClaimedOwnersWindowToAttach() {
        let owner = makePrimary()
        _ = WindowFacadeHolder(owner: owner)
        XCTAssertTrue(KeyWindowRouter.shared.isOwnerClaimed(owner))
        XCTAssertFalse(KeyWindowRouter.shared.hasAttachedWindow(owner))
        var opened = 0
        var ran = false
        WorkspaceSceneReopener.shared.performFileCommand(openScene: { opened += 1 }, action: { facade in
            XCTAssertTrue(facade === owner)
            ran = true
        })
        WorkspaceSceneReopener.shared.noteLaunchSettled()
        XCTAssertEqual(opened, 0, "a launch scene has claimed the owner and is still attaching")
        XCTAssertFalse(ran)

        KeyWindowRouter.shared.attach(makeWindow(), to: owner)
        XCTAssertTrue(ran)
        XCTAssertEqual(opened, 0, "the launch window needs no extra scene")
    }

    func testFileCommandDuringDockReopenWaitsForTheClaimedOwner() {
        let owner = makePrimary()
        _ = WindowFacadeHolder(owner: owner)
        KeyWindowRouter.shared.attach(makeWindow(), to: owner)
        KeyWindowRouter.shared.closeFacade(owner)
        XCTAssertFalse(KeyWindowRouter.shared.isOwnerClaimed(owner))
        let reopened = WindowFacadeHolder(owner: owner)
        XCTAssertTrue(reopened.facade === owner)
        var opened = 0
        var ran: [Int] = []
        WorkspaceSceneReopener.shared.performFileCommand(openScene: { opened += 1 }, action: { _ in
            ran.append(1)
        })
        WorkspaceSceneReopener.shared.performFileCommand(openScene: { opened += 1 }, action: { _ in
            ran.append(2)
        })
        XCTAssertEqual(opened, 0, "the Dock scene has already claimed the owner")
        XCTAssertTrue(ran.isEmpty)

        KeyWindowRouter.shared.attach(makeWindow(), to: owner)
        XCTAssertEqual(ran, [2])
        XCTAssertEqual(opened, 0)
    }

    func testClaimedOwnerCanRetryAfterItsAttachWaitExpires() {
        let owner = makePrimary()
        _ = WindowFacadeHolder(owner: owner)
        WorkspaceSceneReopener.shared.noteLaunchSettled()
        var opened = 0
        var ran: [Int] = []
        WorkspaceSceneReopener.shared.performFileCommand(openScene: { opened += 1 }, action: { _ in
            ran.append(1)
        })
        XCTAssertEqual(opened, 0, "wait for the scene that already claimed the owner")
        WorkspaceSceneReopener.shared.expireOpeningForTesting()
        WorkspaceSceneReopener.shared.performFileCommand(openScene: { opened += 1 }, action: { _ in
            ran.append(2)
        })
        XCTAssertEqual(opened, 1, "an expired claim cannot block the next command forever")

        KeyWindowRouter.shared.attach(makeWindow(), to: owner)
        XCTAssertEqual(ran, [2], "the expired command does not replay")
        KeyWindowRouter.shared.closeFacade(owner)
        _ = WindowFacadeHolder(owner: owner)
        WorkspaceSceneReopener.shared.performFileCommand(openScene: { opened += 1 }, action: { _ in })
        XCTAssertEqual(opened, 1, "a successful attach restores waiting for the next claimed scene")
    }

    private func makePrimary() -> AppState {
        AppState(shouldRestoreLastOpenedFile: false, userDefaults: defaults)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }
}

private struct ReopenQueueProbeError: Error {}
