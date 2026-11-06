import AppKit
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// WD1 (`docs/window-state-gates.md` §4.1, W4 bullets 1–2): a request that would make a file
/// current in window 2 while window 1 shows it brings window 1 forward. Window 2 keeps its
/// document, gets no error, and installs nothing for the file.
@MainActor
final class WindowSameFileFocusAppTests: SharedRootAppTestCase {
    private var windows: [NSWindow] = []
    private var firstWindow: NSWindow!
    private var secondWindow: NSWindow!

    override func setUp() async throws {
        try await super.setUp()
        firstWindow = makeWindow()
        secondWindow = makeWindow()
        KeyWindowRouter.shared.attach(firstWindow, to: primary)
        KeyWindowRouter.shared.attach(secondWindow, to: second)
    }

    override func tearDown() async throws {
        for window in windows {
            window.orderOut(nil)
        }
        windows = []
        firstWindow = nil
        secondWindow = nil
        try await super.tearDown()
    }

    // MARK: - W4 bullet 1: one test per §5.2 entry point

    func testFilesSidebarClickFocusesTheWindowShowingTheFile() async throws {
        let root = try await showSharedA()
        _ = root
        let before = second.shownSession
        let nodeID = try XCTUnwrap(node("a.md", in: second)?.id)
        let deferral = FilesSelectionDeferral()
        var dropped = false
        deferral.open(
            id: nodeID,
            requestingEditorFocus: true,
            pickWindow: secondWindow,
            appState: second,
            onDroppedPick: { dropped = true }
        )
        try await waitUntil("the pick is dropped") { dropped }
        assertFocusedPrimary(leaving: before)
    }

    func testJumpBarSelectionFocusesTheWindowShowingTheFile() async throws {
        _ = try await showSharedA()
        let before = second.shownSession
        let nodeID = try XCTUnwrap(node("a.md", in: second)?.id)

        XCTAssertFalse(second.selectWorkspaceNode(id: nodeID))

        assertFocusedPrimary(leaving: before)
    }

    func testPreviewWorkspaceLinkFocusesTheWindowShowingTheFile() async throws {
        let root = try await showSharedA()
        second.openWorkspaceFile(root.appendingPathComponent("b.md"))
        try await waitUntil("window 2 shows b.md") { self.second.shownSession.fileURL?.lastPathComponent == "b.md" }
        let before = second.shownSession

        second.openPreviewLink("a.md")

        assertFocusedPrimary(leaving: before)
    }

    func testWorkspaceSearchResultFocusesTheWindowShowingTheFile() async throws {
        let root = try await showSharedA()
        let before = second.shownSession
        let authority = try XCTUnwrap(second.workspaceSearchRootAuthority)
        let location = try authority.location(relativePath: "a.md")
        guard case let .regular(identity) = WorkspaceNoFollowFileInspector.status(at: location) else {
            return XCTFail("a.md is not a regular file")
        }
        let text = "alpha text"
        let range = (text as NSString).range(of: "alpha")
        let fileResult = WorkspaceSearchFileResult(
            relativePath: "a.md",
            contentFingerprint: WorkspaceSearchContentFingerprint(text: text),
            matches: [TextSearchMatch(range: range, line: 1, preview: text, previewMatchRange: range)],
            isTruncated: false,
            fileAuthority: WorkspaceSearchFileAuthority(location: location, identity: identity)
        )
        let context = WorkspaceSearchContext(
            rootIdentity: authority.canonicalRootURL.path(percentEncoded: false),
            workspaceGeneration: second.workspaceGeneration,
            queryGeneration: 1
        )
        second.workspaceSearchState = WorkspaceSearchState(
            activeQuery: TextSearchQuery(pattern: "alpha"),
            queryGeneration: 1,
            activeContext: context,
            phase: .completed,
            fileResults: [fileResult]
        )
        _ = root

        XCTAssertFalse(try second.activateWorkspaceSearchResult(
            context: context,
            fileResult: fileResult,
            match: XCTUnwrap(fileResult.matches.first)
        ))

        assertFocusedPrimary(leaving: before)
        if case .navigate? = second.editorNavigationCommand {
            XCTFail("window 2 navigated to the search result")
        }
    }

    func testFinderOrDockOpenFocusesTheWindowShowingTheFile() async throws {
        let root = try await showSharedA()
        firstWindow.orderFront(nil)
        secondWindow.orderFront(nil)
        let before = second.shownSession

        second.openExternalFile(root.appendingPathComponent("a.md"))

        assertFocusedPrimary(leaving: before)
    }

    func testOpenRecentFocusesTheWindowShowingTheFile() async throws {
        let root = try await showSharedA()
        KeyWindowRouter.shared.testingUsesKeyWindowOverride = true
        KeyWindowRouter.shared.testingKeyWindow = secondWindow
        let before = second.shownSession
        var ran = false

        WorkspaceSceneReopener.shared.performFileCommand(openScene: {
            XCTFail("both windows are attached")
        }, action: { facade in
            XCTAssertTrue(facade === self.second)
            ran = true
            facade.routeOpen(root.appendingPathComponent("a.md"))
        })

        XCTAssertTrue(ran)
        assertFocusedPrimary(leaving: before)
    }

    /// Launch restore and every other caller of `open(url:)` refuse before this window
    /// closes its workspace.
    func testDirectOpenRefusesBeforeClosingThisWindowsWorkspace() async throws {
        let root = try await showSharedA()
        XCTAssertThrowsError(try second.open(
            url: root.appendingPathComponent("a.md"),
            rememberAsLastOpened: false,
            preserveWorkspace: false
        )) { error in
            XCTAssertTrue(error is DocumentShownInAnotherWindow, "\(error)")
        }
        XCTAssertNotNil(second.workspaceRootURL, "the refused open did not close window 2's workspace")
        XCTAssertNil(second.shownSession.fileURL)
    }

    func testRecoveryShowEditorCopyFocusesTheWindowShowingTheCopy() async throws {
        _ = try await showSharedA()
        let session = primary.shownSession
        XCTAssertTrue(second.focusOtherWindowShowing(session))
        XCTAssertTrue(KeyWindowRouter.shared.focusedWindowState === primary.windowState)
        XCTAssertNil(second.shownSession.fileURL)
    }

    /// A Finder or Dock open can reach the app just before AppKit activates it. The window
    /// that shows the file comes forward when activation completes.
    func testFocusRequestedWhileInactiveAppliesOnActivation() async throws {
        _ = try await showSharedA()
        // A CI runner activates the hosted app; a local run does not. Pin the inactive path.
        KeyWindowRouter.shared.testingAppIsActive = false
        XCTAssertFalse(firstWindow.isVisible)

        try second.openWorkspaceFile(XCTUnwrap(primary.shownSession.fileURL))

        XCTAssertTrue(KeyWindowRouter.shared.focusedWindowState === primary.windowState)
        XCTAssertTrue(PendingWindowFocus.shared.pendingWindow === firstWindow)
        XCTAssertFalse(firstWindow.isVisible, "nothing moves until the app activates")
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertTrue(firstWindow.isVisible, "activation brought window 1 forward")
        XCTAssertNil(PendingWindowFocus.shared.pendingWindow)
    }

    // MARK: - W4 bullet 2: hard links and case or normalization aliases

    func testAHardLinkInTheSameRootFocusesTheWindowShowingTheOriginal() async throws {
        let root = try makeRoot("blog")
        try FileManager.default.linkItem(
            at: root.appendingPathComponent("a.md"),
            to: root.appendingPathComponent("link.md")
        )
        try await openPair(root: root)
        primary.openWorkspaceFile(root.appendingPathComponent("a.md"))
        try await waitUntil("window 1 shows a.md") { self.primary.shownSession.fileURL?.lastPathComponent == "a.md" }
        let before = second.shownSession
        let nodeID = try XCTUnwrap(node("link.md", in: second)?.id)

        XCTAssertFalse(second.selectWorkspaceNode(id: nodeID))

        assertFocusedPrimary(leaving: before)
        XCTAssertNil(try primary.registry.warmSession(at: XCTUnwrap(
            second.workspaceSearchRootAuthority?.location(relativePath: "link.md").fileURL
        )), "no second session was created for the link")
    }

    func testStandaloneHardLinkCaseAndNormalizationAliasesFocusTheWindowShowingTheFile() throws {
        let folder = directory.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let precomposed = "Caf\u{00E9}.md"
        let decomposed = "Cafe\u{0301}.md"
        let original = folder.appendingPathComponent(precomposed)
        try Data("coffee".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: folder.appendingPathComponent("hard.md"))
        try primary.open(url: original, rememberAsLastOpened: false, preserveWorkspace: false)
        XCTAssertEqual(primary.shownSession.text, "coffee")
        let caseInsensitive = (try? folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames == false

        var aliases = [
            folder.appendingPathComponent("hard.md"),
            folder.appendingPathComponent(decomposed),
        ]
        if caseInsensitive {
            aliases.append(folder.appendingPathComponent("caf\u{00E9}.md"))
        }
        for alias in aliases {
            let before = second.shownSession
            KeyWindowRouter.shared.resetFocusForTesting()
            XCTAssertThrowsError(
                try second.open(url: alias, rememberAsLastOpened: false, preserveWorkspace: false),
                alias.lastPathComponent
            ) { error in
                XCTAssertTrue(error is DocumentShownInAnotherWindow, "\(alias.lastPathComponent): \(error)")
            }
            firstWindow.orderFront(nil)
            secondWindow.orderFront(nil)
            second.openExternalFile(alias)
            XCTAssertTrue(
                KeyWindowRouter.shared.focusedWindowState === primary.windowState,
                alias.lastPathComponent
            )
            XCTAssertTrue(second.shownSession === before, alias.lastPathComponent)
            XCTAssertNil(second.presentedError, alias.lastPathComponent)
        }
    }

    // MARK: - Controls

    /// Warm sessions belong to no window: after window 1 switches away, window 2 adopts it.
    func testAWarmSessionWindowOneLeftIsAdoptedInsteadOfFocused() async throws {
        let root = try await showSharedA()
        let alpha = primary.shownSession
        primary.openWorkspaceFile(root.appendingPathComponent("b.md"))
        try await waitUntil("window 1 shows b.md") { self.primary.shownSession.fileURL?.lastPathComponent == "b.md" }
        let nodeID = try XCTUnwrap(node("a.md", in: second)?.id)

        XCTAssertTrue(second.selectWorkspaceNode(id: nodeID))

        XCTAssertTrue(second.shownSession === alpha)
        XCTAssertNil(KeyWindowRouter.shared.focusedWindowState)
    }

    /// When window 1 cannot come forward, window 2 refuses and both windows stay unchanged.
    func testAWindowThatCannotComeForwardMakesTheOpenRefuse() async throws {
        let root = try await showSharedA()
        KeyWindowRouter.shared.noteCloseApproved(primary)
        let before = second.shownSession
        let nodeID = try XCTUnwrap(node("a.md", in: second)?.id)

        XCTAssertFalse(second.selectWorkspaceNode(id: nodeID))

        XCTAssertNil(KeyWindowRouter.shared.focusedWindowState)
        XCTAssertTrue(second.shownSession === before)
        XCTAssertEqual(second.presentedError?.title, "Already Open in Another Window")
        XCTAssertEqual(primary.shownSession.fileURL?.lastPathComponent, "a.md")
        _ = root
    }

    // MARK: - Helpers

    private func showSharedA() async throws -> URL {
        let root = try makeRoot("blog")
        try await openPair(root: root)
        primary.openWorkspaceFile(root.appendingPathComponent("a.md"))
        try await waitUntil("window 1 shows a.md") {
            self.primary.shownSession.fileURL?.lastPathComponent == "a.md"
        }
        XCTAssertNil(primary.presentedError)
        return root
    }

    private func assertFocusedPrimary(
        leaving before: DocumentSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            KeyWindowRouter.shared.focusedWindowState === primary.windowState,
            "window 1 was not brought forward",
            file: file,
            line: line
        )
        XCTAssertTrue(second.shownSession === before, "window 2 changed its document", file: file, line: line)
        XCTAssertNil(second.presentedError, "window 2 presented an error", file: file, line: line)
        XCTAssertFalse(
            primary.registry.connectedWindows.filter { $0.shownSession === primary.shownSession }.count > 1,
            "two windows show one session",
            file: file,
            line: line
        )
        XCTAssertFalse(
            primary.editorBindingInstallations.contains { _, session in session === primary.shownSession }
                && primary.editorInstallationWindows.contains { _, window in window.window === second.windowState },
            "window 2 installed an editor for the file",
            file: file,
            line: line
        )
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
