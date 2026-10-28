import AppKit
import Combine
import EditorKit
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// Windows PR C: per-window façades, creation guard, close interception, and key routing.
@MainActor
final class WindowFacadeRoutingAppTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var directory: URL!

    override func setUp() async throws {
        suiteName = "WindowFacadeRouting-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowFacadeRouting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        KeyWindowRouter.shared.testingPin = nil
        KeyWindowRouter.shared.testingUsesKeyWindowOverride = false
        KeyWindowRouter.shared.testingKeyWindow = nil
        WindowOpenAdmission.testingBypass = false
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func testRefusedSiblingFailsClosedWithoutConsumingRestore() throws {
        let primary = makePrimary()
        let sibling = primary.makeSiblingFacade(admitsFileOperations: false)
        let file = try write("A.md", "# A\n")

        sibling.restoreLastOpenedFileIfNeeded()
        XCTAssertFalse(primary.didAttemptRestore)

        XCTAssertThrowsError(try sibling.open(
            url: file, rememberAsLastOpened: false, preserveWorkspace: true
        )) { error in
            guard case AppStateError.windowFileOpenRefused = error else {
                return XCTFail("expected windowFileOpenRefused, got \(error)")
            }
        }
        XCTAssertThrowsError(try sibling.openWorkspace(url: directory, rememberAsLastOpened: false)) { error in
            guard case AppStateError.windowFileOpenRefused = error else {
                return XCTFail("expected windowFileOpenRefused, got \(error)")
            }
        }
        sibling.openWorkspaceFile(file)
        XCTAssertEqual(sibling.presentedError?.title, "Could Not Open File")
        sibling.newFile()
        XCTAssertEqual(sibling.presentedError?.title, "Could Not Create File")
        XCTAssertNil(sibling.shownSession.fileURL)
        XCTAssertFalse(primary.registry.connectedWindows.contains { $0 === sibling.windowState })
    }

    func testExternalOpenReachesTheAdmittingFacade() throws {
        let primary = makePrimary()
        let sibling = primary.makeSiblingFacade(admitsFileOperations: false)
        let file = try write("A.md", "# A\n")

        sibling.openExternalFile(file)

        XCTAssertEqual(
            primary.shownSession.fileURL?.resolvingSymlinksInPath().path,
            file.resolvingSymlinksInPath().path
        )
        XCTAssertNil(sibling.shownSession.fileURL)
        XCTAssertNil(sibling.presentedError)
    }

    func testTwoWindowsKeepIndependentDocumentsRootsAndExternalBanners() throws {
        let primary = makePrimary()
        let second = primary.makeSiblingFacade(admitsFileOperations: true)
        let alpha = try write("A.md", "alpha\n")
        let beta = try write("B.md", "beta\n")
        primary.workspaceRootURL = directory.appendingPathComponent("root-a")
        second.workspaceRootURL = directory.appendingPathComponent("root-b")
        let alphaSession = DocumentSession(text: "alpha", url: alpha, fileKind: .markdown)
        let betaSession = DocumentSession(text: "beta", url: beta, fileKind: .markdown)
        XCTAssertEqual(alphaSession.fileURL, alpha)
        primary.shownSession = alphaSession
        second.shownSession = betaSession
        XCTAssertTrue(primary.shownSession === alphaSession)
        XCTAssertEqual(primary.shownSession.fileURL, alpha)
        XCTAssertEqual(second.shownSession.fileURL, beta)
        primary.storeLayoutMode(.sourceOnly)
        second.storeLayoutMode(.sourcePreview)
        primary.editorFindHost.commandContextOverride = true
        second.editorFindHost.commandContextOverride = true
        primary.showOrRefocusEditorFind()
        var secondFind = second.editorFindHost.ui
        secondFind.queryText = "only-b"
        second.editorFindHost.ui = secondFind
        primary.updateWorkspaceSearchQueryText("only-a")
        second.updateWorkspaceSearchQueryText("only-b")

        let alphaKey = try XCTUnwrap(alphaSession.fileURL)
        let betaKey = try XCTUnwrap(betaSession.fileURL)
        XCTAssertTrue(primary.registry.isShownByAnyWindow(second.shownSession))
        primary.pendingExternalTexts[alphaKey] = "alpha from disk"
        primary.restoreRecoveryPrompt(for: primary.shownSession)
        primary.pendingExternalTexts[betaKey] = "beta from disk"
        primary.restoreRecoveryPrompt(for: second.shownSession)

        XCTAssertEqual(primary.externalChangePrompt?.fileURL, alphaKey)
        XCTAssertEqual(second.externalChangePrompt?.fileURL, betaKey)
        XCTAssertNotEqual(primary.workspaceRootURL, second.workspaceRootURL)
        XCTAssertEqual(primary.layoutMode, .sourceOnly)
        XCTAssertEqual(second.layoutMode, .sourcePreview)
        XCTAssertEqual(primary.workspaceSearchUI.queryText, "only-a")
        XCTAssertEqual(second.workspaceSearchUI.queryText, "only-b")
        XCTAssertTrue(primary.editorFindHost.ui.isBarVisible)
        XCTAssertEqual(second.editorFindHost.ui.queryText, "only-b")

        primary.shownSession = DocumentSession(text: "alpha switched", url: alpha, fileKind: .markdown)
        XCTAssertEqual(second.shownSession.text, "beta")
        XCTAssertEqual(second.externalChangePrompt?.fileURL, betaKey)
        XCTAssertEqual(second.layoutMode, .sourcePreview)
    }

    func testCloseInterceptionVetoesAndDefersWithoutReplacingTheDelegate() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let probe = CloseProbe()
        window.delegate = probe
        let interceptor = WindowCloseInterceptor.install(on: window)
        XCTAssertTrue(interceptor.forwarded === probe)

        interceptor.vetoesClose = true
        XCTAssertFalse(interceptor.windowShouldClose(window))
        XCTAssertFalse(probe.asked)

        interceptor.vetoesClose = false
        interceptor.defersClose = true
        XCTAssertFalse(interceptor.windowShouldClose(window))
        XCTAssertFalse(interceptor.defersClose)
        XCTAssertFalse(probe.asked)

        XCTAssertFalse(interceptor.windowShouldClose(window))
        XCTAssertTrue(probe.asked)
    }

    func testAttachedWorkspaceWindowDisallowsTabbing() {
        let primary = makePrimary()
        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.tabbingMode = .automatic
        KeyWindowRouter.shared.attach(window, to: primary)
        XCTAssertEqual(window.tabbingMode, .disallowed)
        window.orderOut(nil)
    }

    func testMenuTargetIgnoresAForeignKeyWindowAndHonorsTheKeyFacade() throws {
        let primary = makePrimary()
        let second = primary.makeSiblingFacade(admitsFileOperations: true)
        let foreign = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let workspace = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        workspace.isReleasedWhenClosed = false
        foreign.isReleasedWhenClosed = false
        KeyWindowRouter.shared.attach(workspace, to: second)
        KeyWindowRouter.shared.testingUsesKeyWindowOverride = true
        KeyWindowRouter.shared.testingKeyWindow = foreign
        XCTAssertNil(KeyWindowRouter.shared.menuTarget(defaultFacade: primary))
        let disabledMenu = MenuBarState()
        XCTAssertFalse(disabledMenu.snapshot.hasActiveWorkspaceWindow)
        XCTAssertFalse(disabledMenu.snapshot.hasOpenDocument)
        XCTAssertFalse(disabledMenu.snapshot.canSave)

        KeyWindowRouter.shared.testingKeyWindow = workspace
        XCTAssertTrue(KeyWindowRouter.shared.menuTarget(defaultFacade: nil) === second)
        second.editorFindHost.commandContextOverride = true
        primary.editorFindHost.commandContextOverride = true
        second.shownSession = try DocumentSession(text: "two", url: write("two.md", "two\n"), fileKind: .markdown)
        primary.shownSession = try DocumentSession(text: "one", url: write("one.md", "one\n"), fileKind: .markdown)
        second.workspaceRootURL = directory
        XCTAssertNotNil(second.workspaceRootURL)
        XCTAssertTrue(second.canUseWorkspaceSearch)
        XCTAssertTrue(KeyWindowRouter.shared.menuTarget(defaultFacade: nil) === second)
        XCTAssertTrue(PlainsongWorkspaceSearchKeyAction.performIfAvailable())
        XCTAssertEqual(second.workspaceSearchUI.mode, .search)
        XCTAssertNotEqual(primary.workspaceSearchUI.mode, .search)
        second.showOrRefocusEditorFind()
        XCTAssertTrue(second.editorFindHost.ui.isBarVisible)
        XCTAssertFalse(primary.editorFindHost.ui.isBarVisible)
        workspace.orderOut(nil)
        foreign.orderOut(nil)
    }

    func testFindCancelReachesTheOriginatingWindow() throws {
        let primary = makePrimary()
        let second = primary.makeSiblingFacade(admitsFileOperations: true)
        primary.shownSession = try DocumentSession(text: "one", url: write("one.md", "one\n"), fileKind: .markdown)
        second.shownSession = try DocumentSession(text: "two", url: write("two.md", "two\n"), fileKind: .markdown)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        KeyWindowRouter.shared.attach(window, to: second)
        EditorFindCommandDelivery.installHooks()
        primary.editorFindHost.commandContextOverride = true
        second.editorFindHost.commandContextOverride = true
        second.showOrRefocusEditorFind()
        primary.showOrRefocusEditorFind()

        XCTAssertEqual(EditorFindActionHooks.cancelFind?(window), true)
        XCTAssertFalse(second.editorFindHost.ui.isBarVisible)
        XCTAssertTrue(primary.editorFindHost.ui.isBarVisible)
        window.orderOut(nil)
    }

    func testPreferencesFanOutReachesEveryFacade() throws {
        let primary = makePrimary()
        let second = primary.makeSiblingFacade(admitsFileOperations: true)
        var primaryHits = 0
        var secondHits = 0
        let first = primary.objectWillChange.sink { _ in primaryHits += 1 }
        let other = second.objectWillChange.sink { _ in secondHits += 1 }
        defer {
            first.cancel()
            other.cancel()
        }

        try primary.preferences.setDefaultFolderURL(nil)

        XCTAssertGreaterThan(primaryHits, 0)
        XCTAssertGreaterThan(secondHits, 0)
    }

    func testRecoveryBannerAndUnseenFailureStayOnTheHomeWindow() {
        let primary = makePrimary()
        let second = primary.makeSiblingFacade(admitsFileOperations: true)
        primary.workspaceMutationTextRecoveryLoadFailed = true
        XCTAssertEqual(primary.workspaceMutationRecoveryBannerPlacement, .global)
        XCTAssertEqual(second.workspaceMutationRecoveryBannerPlacement, .hidden)

        let unseen = DocumentSession(
            text: "warm",
            url: directory.appendingPathComponent("warm.md"),
            fileKind: .markdown
        )
        primary.present(
            AppStateError.windowFileOpenRefused,
            title: "Autosave Failed",
            for: unseen
        )
        XCTAssertEqual(primary.presentedError?.title, "Autosave Failed")
        XCTAssertNil(second.presentedError)
    }

    func testClosingAFacadeRetargetsItsNotice() throws {
        let primary = makePrimary()
        let second = primary.makeSiblingFacade(admitsFileOperations: true)
        let destination = try write("saved.md", "saved\n")
        let notice = try FileWriteArtifactNotice(
            destinationURL: destination,
            destinationWasCommitted: true,
            artifactState: .retained(WorkspaceFileSystemLocation(fileURL: destination))
        )
        primary.fileWriteArtifactNotices.append(notice)
        KeyWindowRouter.shared.routeNotice(notice.id, owner: primary)

        KeyWindowRouter.shared.closeFacade(primary)

        XCTAssertTrue(
            KeyWindowRouter.shared.noticeFacade(for: notice.id, registry: second.registry) === second
        )
    }

    func testBackgroundFacadePublishDoesNotRepublishTheMenu() async throws {
        let primary = makePrimary()
        let second = primary.makeSiblingFacade(admitsFileOperations: true)
        second.workspaceRootURL = directory
        KeyWindowRouter.shared.testingPin = primary
        let menu = MenuBarState()
        var publishes = 0
        let subscription = menu.$snapshot.dropFirst().sink { _ in publishes += 1 }
        defer { subscription.cancel() }

        second.updateWorkspaceSearchQueryText("alpha")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(publishes, 0)

        primary.recentItemURLs = [directory.appendingPathComponent("A.md")]
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(menu.snapshot.recentItemURLs, primary.recentItemURLs)
        XCTAssertGreaterThan(publishes, 0)
    }

    private func makePrimary() -> AppState {
        AppState(shouldRestoreLastOpenedFile: false, userDefaults: defaults)
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}

private final class CloseProbe: NSObject, NSWindowDelegate {
    var asked = false

    func windowShouldClose(_: NSWindow) -> Bool {
        asked = true
        return false
    }
}
