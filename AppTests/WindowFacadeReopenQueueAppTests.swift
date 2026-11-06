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

    func testClaimedOwnerCanRetryAfterItsAttachWaitExpires() throws {
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
        XCTAssertFalse(
            KeyWindowRouter.shared.isOwnerClaimed(owner),
            "an expired attach wait releases the claim that never attached"
        )
        var replacement: WindowFacadeHolder?
        WorkspaceSceneReopener.shared.performFileCommand(openScene: {
            opened += 1
            replacement = WindowFacadeHolder(owner: owner)
        }, action: { _ in
            ran.append(2)
        })
        XCTAssertEqual(opened, 1, "an expired claim cannot block the next command forever")
        let current = try XCTUnwrap(replacement)
        XCTAssertTrue(current.facade === owner)

        try KeyWindowRouter.shared.attach(
            makeWindow(),
            to: owner,
            ownerClaimToken: XCTUnwrap(current.ownerClaimToken)
        )
        XCTAssertEqual(ran, [2], "the expired command does not replay")
        KeyWindowRouter.shared.closeFacade(owner)
        XCTAssertTrue(
            owner.registry.connectedWindows.contains { $0 === owner.windowState },
            "closing the retried owner keeps its document"
        )
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

/// An expired owner claim must be claimable again, and the retired scene's window
/// must not take that claim back.
@MainActor
final class WindowFacadeExpiredClaimAppTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        KeyWindowRouter.shared.resetForTesting()
        suiteName = "WindowFacadeExpiredClaim-\(UUID().uuidString)"
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

    func testExpiredClaimReopensOntoTheOwnerAndIgnoresTheOldScene() async throws {
        let owner = makePrimary()
        let stale = WindowFacadeHolder(owner: owner)
        let staleToken = try XCTUnwrap(stale.ownerClaimToken)
        WorkspaceSceneReopener.shared.noteLaunchSettled()
        var opened = 0
        var ran = 0
        WorkspaceSceneReopener.shared.performFileCommand(openScene: { opened += 1 }, action: { facade in
            XCTAssertTrue(facade === owner)
            ran += 1
        })
        XCTAssertEqual(opened, 0)
        WorkspaceSceneReopener.shared.expireOpeningForTesting()

        var replacement: WindowFacadeHolder?
        WorkspaceSceneReopener.shared.performFileCommand(openScene: {
            opened += 1
            replacement = WindowFacadeHolder(owner: owner)
        }, action: { facade in
            XCTAssertTrue(facade === owner)
            ran += 1
        })
        let current = try XCTUnwrap(replacement)
        XCTAssertTrue(current.facade === owner, "the retry claims the owner instead of a refused sibling")
        XCTAssertTrue(WindowOpenAdmission.admits(current.facade.windowState))
        let currentToken = try XCTUnwrap(current.ownerClaimToken)
        XCTAssertNotEqual(currentToken, staleToken)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(ran, 0)

        owner.externalChangePrompt = AppState.ExternalChangePrompt(
            fileURL: URL(fileURLWithPath: "/tmp/expired-claim.md")
        )
        let staleWindow = makeWindow()
        let veto = ExpiredClaimVetoDelegate()
        staleWindow.delegate = veto
        staleWindow.orderFront(nil)
        KeyWindowRouter.shared.attach(staleWindow, to: owner, ownerClaimToken: staleToken)
        XCTAssertEqual(ran, 0, "the retired scene does not run the retry")
        XCTAssertFalse(KeyWindowRouter.shared.hasAttachedWindow(owner))
        XCTAssertNil(KeyWindowRouter.shared.facade(for: staleWindow))
        XCTAssertTrue(KeyWindowRouter.shared.isOwnerClaimed(owner))
        XCTAssertNotNil(owner.externalChangePrompt)
        try await waitUntilClosed(veto)
        XCTAssertNotNil(owner.externalChangePrompt)
        XCTAssertTrue(KeyWindowRouter.shared.facades(in: owner.registry).contains { $0 === owner })

        let replacementWindow = makeWindow()
        KeyWindowRouter.shared.attach(replacementWindow, to: owner, ownerClaimToken: currentToken)
        XCTAssertEqual(ran, 1)
        XCTAssertTrue(KeyWindowRouter.shared.facade(for: replacementWindow) === owner)
        XCTAssertNotNil(owner.externalChangePrompt)
    }

    func testLateRetiredSceneCannotReplaceTheAttachedOwner() async throws {
        let owner = makePrimary()
        let stale = WindowFacadeHolder(owner: owner)
        let staleToken = try XCTUnwrap(stale.ownerClaimToken)
        WorkspaceSceneReopener.shared.noteLaunchSettled()
        WorkspaceSceneReopener.shared.performFileCommand(openScene: {}, action: { _ in })
        WorkspaceSceneReopener.shared.expireOpeningForTesting()
        let replacement = WindowFacadeHolder(owner: owner)
        let currentToken = try XCTUnwrap(replacement.ownerClaimToken)
        let replacementWindow = makeWindow()
        KeyWindowRouter.shared.attach(replacementWindow, to: owner, ownerClaimToken: currentToken)
        owner.externalChangePrompt = AppState.ExternalChangePrompt(
            fileURL: URL(fileURLWithPath: "/tmp/expired-claim.md")
        )

        let staleWindow = makeWindow()
        let veto = ExpiredClaimVetoDelegate()
        staleWindow.delegate = veto
        staleWindow.orderFront(nil)
        KeyWindowRouter.shared.attach(staleWindow, to: owner, ownerClaimToken: staleToken)
        try await waitUntilClosed(veto)

        XCTAssertTrue(KeyWindowRouter.shared.facade(for: replacementWindow) === owner)
        XCTAssertNil(KeyWindowRouter.shared.facade(for: staleWindow))
        XCTAssertTrue(KeyWindowRouter.shared.isOwnerClaimed(owner))
        XCTAssertNotNil(owner.externalChangePrompt)
        XCTAssertTrue(KeyWindowRouter.shared.hasAttachedWindow(owner))
    }

    private func waitUntilClosed(_ delegate: ExpiredClaimVetoDelegate) async throws {
        let deadline = Date().addingTimeInterval(2)
        while delegate.willCloseCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(delegate.willCloseCount, 1)
        XCTAssertFalse(delegate.asked)
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

private final class ExpiredClaimVetoDelegate: NSObject, NSWindowDelegate {
    var asked = false
    var willCloseCount = 0

    func windowShouldClose(_: NSWindow) -> Bool {
        asked = true
        return false
    }

    func windowWillClose(_: Notification) {
        willCloseCount += 1
    }
}
