import AppKit
import Combine
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// Windows PR C review: scene reuse after close, close bookkeeping, sheet-key routing,
/// background-failure focus, and every window's termination and autosave inputs.
@MainActor
final class WindowFacadeLifecycleAppTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var directory: URL!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        KeyWindowRouter.shared.resetForTesting()
        suiteName = "WindowFacadeLifecycle-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowFacadeLifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for window in windows {
            window.orderOut(nil)
        }
        windows = []
        KeyWindowRouter.shared.resetForTesting()
        WindowOpenAdmission.resetForTesting()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Review blocking 1: closing the only window must not leave the next scene refused.
    func testClosingTheOwnersWindowLetsTheNextSceneReuseTheOwner() throws {
        let owner = makePrimary()
        let first = WindowFacadeHolder(owner: owner)
        XCTAssertTrue(first.facade === owner)
        autoreleasepool {
            let extra = WindowFacadeHolder(owner: owner)
            XCTAssertFalse(extra.facade === owner, "a scene opened while the owner shows is a sibling")
            XCTAssertFalse(WindowOpenAdmission.admits(extra.facade.windowState))
            XCTAssertTrue(KeyWindowRouter.shared.home(for: owner.registry) === owner, "a refused scene is never home")
        }

        let blocked = try write("blocked.md", "blocked\n")
        try owner.open(url: blocked, rememberAsLastOpened: false, preserveWorkspace: true)
        owner.registry.pendingExternalTexts[blocked] = "changed on disk\n"
        owner.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: blocked)
        XCTAssertTrue(owner.isSaveBlockedByWindowPrompt(at: blocked))

        let window = makeWindow()
        KeyWindowRouter.shared.attach(window, to: owner)
        window.orderFront(nil)
        window.performClose(nil)
        XCTAssertNil(owner.externalChangePrompt)
        XCTAssertFalse(
            owner.isSaveBlockedByWindowPrompt(at: blocked),
            "a closed owner's prompt does not block other windows"
        )
        XCTAssertEqual(owner.registry.pendingExternalTexts[blocked], "changed on disk\n")
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(KeyWindowRouter.shared.facades(in: owner.registry).contains { $0 === owner })
        XCTAssertTrue(
            owner.registry.connectedWindows.contains { $0 === owner.windowState },
            "the owner keeps its document for the next scene"
        )

        // With no window open, a registry input still advances the shared Replace generation.
        XCTAssertTrue(KeyWindowRouter.shared.facades(in: owner.registry).isEmpty)
        let closedGeneration = owner.registry.replaceAuthority.generation
        owner.registry.detachedSessionURLs.insert(directory.appendingPathComponent("gone.md"))
        XCTAssertGreaterThan(owner.registry.replaceAuthority.generation, closedGeneration)
        owner.registry.detachedSessionURLs.removeAll()

        let reopened = WindowFacadeHolder(owner: owner)
        XCTAssertTrue(reopened.facade === owner, "Dock reopen or a Finder open gets the owner back")
        XCTAssertEqual(owner.externalChangePrompt?.fileURL, blocked)
        XCTAssertTrue(KeyWindowRouter.shared.isHome(owner))
        KeyWindowRouter.shared.testingUsesKeyWindowOverride = true
        KeyWindowRouter.shared.testingKeyWindow = nil
        XCTAssertTrue(KeyWindowRouter.shared.menuTarget(defaultFacade: nil) === owner)
        let file = try write("A.md", "# A\n")
        try owner.open(url: file, rememberAsLastOpened: false, preserveWorkspace: true)
        XCTAssertEqual(owner.shownSession.fileURL?.lastPathComponent, "A.md")
    }

    /// Review should-fix 3, 4, 12: a closed sibling leaves every inventory, its prompt stops
    /// blocking saves, and neither the router nor a close observer keeps it alive.
    func testClosingASiblingWindowReleasesItEverywhere() throws {
        let primary = makePrimary()
        weak var weakSibling: AppState?
        weak var weakSiblingWindow: WindowState?
        let file = try write("shared.md", "shared\n")
        let window = makeWindow()
        try autoreleasepool {
            let sibling = primary.makeSiblingFacade(admitsFileOperations: true)
            weakSibling = sibling
            weakSiblingWindow = sibling.windowState
            // Before attach, so the record is kept without making the test window key.
            KeyWindowRouter.shared.focus(sibling.windowState)
            XCTAssertTrue(KeyWindowRouter.shared.focusedWindowState === sibling.windowState)
            KeyWindowRouter.shared.attach(window, to: sibling)
            window.orderFront(nil)
            var published = 0
            let counter = KeyWindowRouter.shared.objectWillChange.sink { _ in published += 1 }
            KeyWindowRouter.shared.attach(window, to: sibling)
            counter.cancel()
            XCTAssertEqual(published, 0, "re-attaching the same window is a no-op")

            sibling.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: file)
            XCTAssertTrue(primary.isSaveBlockedByWindowPrompt(at: file))
            let notice = try FileWriteArtifactNotice(
                destinationURL: file,
                destinationWasCommitted: true,
                artifactState: .retained(WorkspaceFileSystemLocation(fileURL: file))
            )
            KeyWindowRouter.shared.routeNotice(notice.id, owner: sibling)

            window.performClose(nil)

            XCTAssertFalse(primary.registry.connectedWindows.contains { $0 === sibling.windowState })
            XCTAssertFalse(primary.isSaveBlockedByWindowPrompt(at: file))
            XCTAssertFalse(WindowOpenAdmission.admits(sibling.windowState))
            XCTAssertTrue(
                KeyWindowRouter.shared.noticeFacade(for: notice.id, registry: primary.registry) === primary
            )
        }
        XCTAssertNil(weakSibling, "no router table or close observer retains a closed façade")
        XCTAssertNil(weakSiblingWindow)
        XCTAssertNil(KeyWindowRouter.shared.focusedWindowState)
    }

    /// Review should-fix 7: a sheet or child window resolves to its workspace window, and
    /// several windows with no key window resolve to nothing.
    func testMenuTargetFollowsASheetToItsWindowAndNeverGuesses() {
        let primary = makePrimary()
        let second = primary.makeSiblingFacade(admitsFileOperations: true)
        let workspace = makeWindow()
        KeyWindowRouter.shared.attach(workspace, to: second)
        workspace.orderFront(nil)
        let child = makeWindow()
        workspace.addChildWindow(child, ordered: .above)
        KeyWindowRouter.shared.testingUsesKeyWindowOverride = true

        KeyWindowRouter.shared.testingKeyWindow = child
        XCTAssertTrue(KeyWindowRouter.shared.menuTarget(defaultFacade: nil) === second)

        let sheet = makeWindow()
        workspace.beginSheet(sheet)
        XCTAssertTrue(sheet.sheetParent === workspace)
        KeyWindowRouter.shared.testingKeyWindow = sheet
        XCTAssertTrue(KeyWindowRouter.shared.menuTarget(defaultFacade: nil) === second)
        workspace.endSheet(sheet)
        workspace.removeChildWindow(child)

        KeyWindowRouter.shared.testingKeyWindow = nil
        XCTAssertNil(KeyWindowRouter.shared.menuTarget(defaultFacade: nil), "two windows, no key window")
        XCTAssertTrue(KeyWindowRouter.shared.menuTarget(defaultFacade: primary) === primary)
    }

    /// Review should-fix 8: a background failure shows on its window without focusing it.
    /// Only a refusal the user caused (Quit) brings its window forward.
    func testBackgroundFailureDoesNotFocusItsWindow() throws {
        let primary = makePrimary()
        let second = primary.makeSiblingFacade(admitsFileOperations: true)
        second.shownSession = try DocumentSession(text: "b", url: write("b.md", "b\n"), fileKind: .markdown)

        primary.present(AppStateError.windowFileOpenRefused, title: "Autosave Failed", for: second.shownSession)
        XCTAssertEqual(second.presentedError?.title, "Autosave Failed")
        XCTAssertNil(KeyWindowRouter.shared.focusedWindowState)

        second.dismissError()
        primary.present(
            AppStateError.windowFileOpenRefused,
            title: "Could Not Quit",
            for: second.shownSession,
            activatesWindow: true
        )
        XCTAssertTrue(KeyWindowRouter.shared.focusedWindowState === second.windowState)
    }

    /// Review should-fix 9: an image insertion in another window's root blocks Quit.
    func testTerminationRefusesWhileAnotherWindowInsertsAnImage() {
        let primary = makePrimary()
        let second = primary.makeSiblingFacade(admitsFileOperations: true)
        second.workspaceImageAssetInsertionCount += 1

        XCTAssertFalse(primary.prepareForTermination())
        XCTAssertEqual(second.presentedError?.title, "Could Not Quit")
        XCTAssertNil(primary.presentedError)
        XCTAssertTrue(KeyWindowRouter.shared.focusedWindowState === second.windowState)

        second.workspaceImageAssetInsertionCount -= 1
        second.dismissError()
        XCTAssertTrue(primary.prepareForTermination())
    }

    /// Review should-fix 10: any window cancels the home document's foreground autosave, and
    /// closing the home window hands that autosave to the per-session background task.
    func testForegroundAutosaveIsCancelledFromAnyWindowAndSurvivesAHomeClose() throws {
        let primary = makePrimary()
        let second = primary.makeSiblingFacade(admitsFileOperations: true)
        try primary.open(url: write("home.md", "home\n"), rememberAsLastOpened: false, preserveWorkspace: true)
        let session = primary.shownSession
        XCTAssertTrue(KeyWindowRouter.shared.isHome(primary))

        primary.replaceDocumentText("home edited\n", in: session)
        primary.scheduleAutosave()
        XCTAssertNotNil(primary.registry.autosaveTask)
        second.cancelAutosave(for: session)
        XCTAssertNil(primary.registry.autosaveTask, "a sibling's cancel reaches the shared timer")

        primary.scheduleAutosave()
        XCTAssertNotNil(primary.registry.autosaveTask)
        KeyWindowRouter.shared.closeFacade(primary)
        XCTAssertNil(primary.registry.autosaveTask)
        XCTAssertNotNil(primary.registry.sessionAutosaveTasks[ObjectIdentifier(session)])
        XCTAssertTrue(KeyWindowRouter.shared.isHome(second))
        primary.cancelAutosave(for: session)
    }

    /// W0 bullet 4: a real `performClose` through the interceptor. The wrapped delegate stays
    /// alive while the window is open, sees `windowWillClose` once, and gets the window back.
    func testCloseInterceptionVetoesAndDefersWithoutReplacingTheDelegate() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        weak var weakProbe: CloseProbe?
        let interceptor: WindowCloseInterceptor
        do {
            let probe = CloseProbe()
            weakProbe = probe
            window.delegate = probe
            interceptor = WindowCloseInterceptor.install(on: window)
            XCTAssertTrue(interceptor.forwarded === probe)
        }
        // NSWindow holds its delegate weakly; the interceptor keeps the probe alive.
        let probe = try XCTUnwrap(weakProbe)
        window.orderFront(nil)
        window.setContentSize(NSSize(width: 160, height: 100))
        XCTAssertGreaterThan(probe.resizeCount, 0, "unrelated delegate messages still forward")

        interceptor.vetoesClose = true
        window.performClose(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(probe.asked)

        interceptor.vetoesClose = false
        interceptor.defersClose = true
        window.performClose(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(interceptor.defersClose)
        XCTAssertFalse(probe.asked)

        window.performClose(nil)
        XCTAssertTrue(probe.asked)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(probe.willCloseCount, 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(window.delegate === probe, "the window gets its own delegate back")
        XCTAssertNil(interceptor.forwarded)
        XCTAssertEqual(probe.willCloseCount, 1)
    }

    func testFileCommandWithNoWindowReopensTheOwnerAndRunsThere() {
        let owner = makePrimary()
        _ = WindowFacadeHolder(owner: owner)
        let window = makeWindow()
        KeyWindowRouter.shared.attach(window, to: owner)
        KeyWindowRouter.shared.closeFacade(owner)
        XCTAssertNil(KeyWindowRouter.shared.menuTarget(defaultFacade: nil))
        XCTAssertFalse(KeyWindowRouter.shared.hasAttachedWindow(owner))

        var opened = 0
        var ran = 0
        WorkspaceSceneReopener.shared.performFileCommand(openScene: { opened += 1 }, action: { facade in
            XCTAssertTrue(facade === owner)
            ran += 1
        })
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(ran, 0, "the command waits until the new scene attaches the owner")
        WorkspaceSceneReopener.shared.performFileCommand(openScene: { opened += 1 }, action: { _ in
            ran += 1
        })
        XCTAssertEqual(opened, 1, "a second command does not open another scene")

        _ = WindowFacadeHolder(owner: owner)
        KeyWindowRouter.shared.attach(makeWindow(), to: owner)
        XCTAssertEqual(ran, 2)
        XCTAssertTrue(KeyWindowRouter.shared.menuTarget(defaultFacade: nil) === owner)
    }

    func testFileCommandBeforeTheFirstSceneWaitsForItsWindow() {
        let owner = makePrimary()
        WorkspaceSceneReopener.shared.remember(owner)
        var opened = 0
        var ran = false
        WorkspaceSceneReopener.shared.performFileCommand(openScene: { opened += 1 }, action: { facade in
            XCTAssertTrue(facade === owner)
            ran = true
        })
        XCTAssertEqual(opened, 0, "SwiftUI is already opening the launch scene")
        XCTAssertFalse(ran)
        _ = WindowFacadeHolder(owner: owner)
        KeyWindowRouter.shared.attach(makeWindow(), to: owner)
        XCTAssertTrue(ran)
    }

    func testFileCommandWithSeveralWindowsAndNoKeyWindowDoesNotGuess() {
        let owner = makePrimary()
        _ = WindowFacadeHolder(owner: owner)
        let sibling = owner.makeSiblingFacade(admitsFileOperations: true)
        KeyWindowRouter.shared.attach(makeWindow(), to: owner)
        KeyWindowRouter.shared.attach(makeWindow(), to: sibling)
        KeyWindowRouter.shared.testingUsesKeyWindowOverride = true
        KeyWindowRouter.shared.testingKeyWindow = nil
        var opened = false
        var ran = false
        WorkspaceSceneReopener.shared.performFileCommand(openScene: { opened = true }, action: { _ in
            ran = true
        })
        XCTAssertFalse(opened)
        XCTAssertFalse(ran)
    }

    func testQuitRefusalForAClosedSessionUsesAnAttachedHome() {
        let owner = makePrimary()
        _ = WindowFacadeHolder(owner: owner)
        KeyWindowRouter.shared.attach(makeWindow(), to: owner)
        let sibling = owner.makeSiblingFacade(admitsFileOperations: true)
        KeyWindowRouter.shared.attach(makeWindow(), to: sibling)
        XCTAssertFalse(sibling.shownSession === owner.shownSession)
        KeyWindowRouter.shared.closeFacade(owner)
        var opened = false
        WorkspaceSceneReopener.shared.installOpenScene { opened = true }
        owner.present(
            LifecycleProbeError(),
            title: "Could Not Quit",
            for: owner.shownSession,
            activatesWindow: true
        )
        XCTAssertEqual(sibling.presentedError?.title, "Could Not Quit")
        XCTAssertNil(owner.presentedError)
        XCTAssertTrue(KeyWindowRouter.shared.focusedWindowState === sibling.windowState)
        XCTAssertFalse(opened)
    }

    func testQuitRefusalWithNoWindowReopensTheOwnerBeforeShowingTheError() {
        let owner = makePrimary()
        _ = WindowFacadeHolder(owner: owner)
        KeyWindowRouter.shared.attach(makeWindow(), to: owner)
        KeyWindowRouter.shared.closeFacade(owner)
        var opened = 0
        WorkspaceSceneReopener.shared.installOpenScene { opened += 1 }
        owner.presentOnHome(LifecycleProbeError(), title: "Could Not Quit")
        XCTAssertEqual(opened, 1)
        XCTAssertNil(owner.presentedError)

        _ = WindowFacadeHolder(owner: owner)
        KeyWindowRouter.shared.attach(makeWindow(), to: owner)
        XCTAssertEqual(owner.presentedError?.title, "Could Not Quit")
    }

    func testRefusedSceneClosesWithoutAskingAVetoingDelegate() async throws {
        let owner = makePrimary()
        _ = WindowFacadeHolder(owner: owner)
        KeyWindowRouter.shared.closeFacade(owner)
        let sibling = owner.makeSiblingFacade(admitsFileOperations: false)
        let window = makeWindow()
        let veto = VetoCloseDelegate()
        window.delegate = veto
        window.orderFront(nil)
        KeyWindowRouter.shared.attach(window, to: sibling)
        XCTAssertNil(
            KeyWindowRouter.shared.home(for: owner.registry),
            "a refused scene is not home while it is waiting to close"
        )
        let deadline = Date().addingTimeInterval(2)
        while window.isVisible, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(veto.asked)
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

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}

private final class CloseProbe: NSObject, NSWindowDelegate {
    var asked = false
    var willCloseCount = 0
    var resizeCount = 0

    func windowShouldClose(_: NSWindow) -> Bool {
        asked = true
        return true
    }

    func windowWillClose(_: Notification) {
        willCloseCount += 1
    }

    func windowDidResize(_: Notification) {
        resizeCount += 1
    }
}

private struct LifecycleProbeError: Error {}

private final class VetoCloseDelegate: NSObject, NSWindowDelegate {
    var asked = false

    func windowShouldClose(_: NSWindow) -> Bool {
        asked = true
        return false
    }
}
