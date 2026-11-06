import AppKit
import EditorKit
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// Windows PR D2: closing a window (`docs/window-state-gates.md` §6.2, W7 bullets 1, 2, and 4,
/// WD8). Each façade has a real `NSWindow` attached through `KeyWindowRouter`, so
/// `performClose` reaches the façade's `windowShouldClose` and `willClose`.
@MainActor
final class WindowCloseLifecycleAppTests: SharedRootAppTestCase {
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

    // MARK: - W7 bullet 1: a dirty, savable document is saved

    func testClosingAWindowSavesItsDirtyStandaloneDocumentAndKeepsItWarm() throws {
        let url = try writeLoose("loose.md", "loose")
        try second.open(url: url, rememberAsLastOpened: false, preserveWorkspace: false)
        let session = second.shownSession
        second.replaceDocumentText("loose edited", in: session)
        let stateURL = try XCTUnwrap(second.sessionStateURL(for: session))

        secondWindow.performClose(nil)

        XCTAssertFalse(KeyWindowRouter.shared.hasAttachedWindow(second), "the window closed")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "loose edited")
        XCTAssertFalse(session.isDirty)
        XCTAssertTrue(primary.registry.isWarmSession(session, at: stateURL), "a saved session stays warm")
        XCTAssertFalse(primary.registry.connectedWindows.contains { $0 === second.windowState })
        XCTAssertNil(second.shownSession.fileURL, "a closed window keeps no document")
    }

    func testClosingOneOfTwoWindowsOnARootKeepsTheRootAndItsSavedDocumentWarm() async throws {
        let root = try makeRoot("blog")
        try await openPair(root: root)
        second.openWorkspaceFile(root.appendingPathComponent("b.md"))
        try await waitUntil("window 2 shows b.md") { self.second.shownSession.fileURL?.lastPathComponent == "b.md" }
        let session = second.shownSession
        second.replaceDocumentText("beta edited", in: session)
        let context = primary.workspaceRootContext
        let stateURL = try XCTUnwrap(second.sessionStateURL(for: session))

        secondWindow.performClose(nil)

        XCTAssertFalse(KeyWindowRouter.shared.hasAttachedWindow(second))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b.md"), encoding: .utf8), "beta edited")
        XCTAssertTrue(primary.registry.isWarmSession(session, at: stateURL))
        XCTAssertTrue(primary.workspaceRootContext === context)
        XCTAssertEqual(context.facades.map(ObjectIdentifier.init), [ObjectIdentifier(primary)])
        XCTAssertNotNil(primary.workspaceRootURL)
        XCTAssertNil(second.workspaceRootURL)
    }

    func testClosingTheLastWindowOnARootSavesAndReleasesTheRoot() async throws {
        let root = try makeRoot("blog")
        try await open(primary, root: root)
        primary.openWorkspaceFile(root.appendingPathComponent("a.md"))
        try await waitUntil("window 1 shows a.md") { self.primary.shownSession.fileURL?.lastPathComponent == "a.md" }
        let session = primary.shownSession
        primary.replaceDocumentText("alpha edited", in: session)
        let authority = try XCTUnwrap(primary.workspaceRootContext.registrationAuthority)

        firstWindow.performClose(nil)

        XCTAssertFalse(KeyWindowRouter.shared.hasAttachedWindow(primary))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.md"), encoding: .utf8), "alpha edited")
        XCTAssertNil(primary.registry.workspaceRoots[authority]?.context, "the last window released its root")
        XCTAssertNil(primary.workspaceRootURL)
        XCTAssertTrue(primary.isEmptyWorkspaceWindow, "the app-owned façade reopens empty")
    }

    // MARK: - W7 bullet 2: WD8 refusals and retention

    func testTransientAndQuarantinedStatesRefuseTheCloseWithoutLoss() throws {
        let cases: [(String, @MainActor (AppState, DocumentSession) -> Void)] = [
            ("pending editor source", { facade, session in
                facade.pendingEditorSourceInstallations[EditorDocumentBindingInstallation(
                    bindingID: EditorDocumentBindingID(),
                    installationID: EditorDocumentBindingInstallationID()
                )] = session
            }),
            ("disk inspection", { facade, session in
                let url = facade.sessionStateURL(for: session)!
                facade.externalDiskInspectionTasks[ObjectIdentifier(session)] = ExternalDiskInspectionTask(
                    token: UUID(), session: session, canonicalURL: url,
                    location: try! WorkspaceFileSystemLocation(fileURL: url),
                    lifecycleGeneration: 0, diskEventGeneration: 0,
                    sourceSnapshot: EditorDocumentSourceSnapshot(source: session.text, revision: session.version),
                    task: Task {}
                )
            }),
            ("pending source on another of this window's editors", { facade, _ in
                let earlier = DocumentSession(text: "earlier", url: URL(fileURLWithPath: "/tmp/earlier.md"))
                let installation = EditorDocumentBindingInstallation(
                    bindingID: EditorDocumentBindingID(),
                    installationID: EditorDocumentBindingInstallationID()
                )
                facade.editorBindingInstallations[installation] = earlier
                facade.editorInstallationWindows[installation] = RegisteredWindowState(window: facade.windowState)
                facade.pendingEditorSourceInstallations[installation] = earlier
            }),
            ("namespace mutation", { facade, _ in facade.workspaceMutationNamespaceDepth = 1 }),
            ("image insertion", { facade, _ in
                facade.registry.activeImageInsertions[UUID()] = (
                    RegisteredWindowState(window: facade.windowState), URL(fileURLWithPath: "/tmp")
                )
            }),
            ("indeterminate write", { facade, session in
                facade.indeterminateSessionWrites[ObjectIdentifier(session)] = WorkspaceIndeterminateFileWrite(
                    reason: .durabilityFailed, preparedMetadata: nil, recoveryArtifact: .none
                )
            }),
            ("mutation quarantine", { facade, session in
                facade.indeterminateWorkspaceMutationSessions.insert(ObjectIdentifier(session))
            }),
            ("write fence", { facade, session in
                facade.workspaceMutationWriteFences.insert(ObjectIdentifier(session))
            }),
        ]
        for (index, (name, block)) in cases.enumerated() {
            let url = try writeLoose("blocked-\(index).md", "blocked")
            try second.open(url: url, rememberAsLastOpened: false, preserveWorkspace: false)
            let session = second.shownSession
            second.replaceDocumentText("unsaved \(name)", in: session)
            block(second, session)

            secondWindow.performClose(nil)

            XCTAssertTrue(KeyWindowRouter.shared.hasAttachedWindow(second), "\(name): the window stayed open")
            XCTAssertTrue(second.shownSession === session, name)
            XCTAssertEqual(session.text, "unsaved \(name)", name)
            XCTAssertEqual(second.presentedError?.title, "Could Not Close Window", name)
            XCTAssertFalse(KeyWindowRouter.shared.isClosing(second), name)
            XCTAssertTrue(primary.registry.connectedWindows.contains { $0 === second.windowState }, name)
            // Undo the fixture so the next case starts clean.
            second.pendingEditorSourceInstallations = [:]
            second.editorBindingInstallations = second.editorBindingInstallations.filter { $0.value === session }
            second.editorInstallationWindows = [:]
            second.externalDiskInspectionTasks = [:]
            second.workspaceMutationNamespaceDepth = 0
            second.registry.activeImageInsertions = [:]
            second.indeterminateSessionWrites = [:]
            second.indeterminateWorkspaceMutationSessions = []
            second.workspaceMutationWriteFences = []
            second.dismissError()
        }
    }

    /// A conflicted document closes and stays warm; its text, authority, and prompt come back
    /// when another window shows it.
    func testAConflictedDocumentClosesAndItsPromptReturnsInTheNextWindowThatShowsIt() throws {
        let url = try writeLoose("conflict.md", "original")
        try second.open(url: url, rememberAsLastOpened: false, preserveWorkspace: false)
        let session = second.shownSession
        second.replaceDocumentText("mine", in: session)
        let stateURL = try XCTUnwrap(second.sessionStateURL(for: session))
        second.pendingExternalTexts[stateURL] = "theirs"
        second.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: stateURL)
        XCTAssertFalse(second.canAutosave(session: session))
        XCTAssertTrue(second.hasCloseRetentionProof(for: session))

        secondWindow.performClose(nil)

        XCTAssertFalse(KeyWindowRouter.shared.hasAttachedWindow(second))
        XCTAssertTrue(primary.registry.isWarmSession(session, at: stateURL))
        XCTAssertEqual(primary.pendingExternalTexts[stateURL], "theirs")
        XCTAssertEqual(session.text, "mine")
        XCTAssertNotNil(primary.retainedManagedSessionLocation(for: session))
        XCTAssertTrue(primary.workspaceMutationTerminationSessions().contains { $0 === session })
        XCTAssertFalse(primary.isSaveBlockedByWindowPrompt(at: stateURL), "the closed window's prompt is gone")

        try primary.open(url: url, rememberAsLastOpened: false, preserveWorkspace: false)

        XCTAssertTrue(primary.shownSession === session, "window 1 adopts the warm session")
        XCTAssertEqual(primary.externalChangePrompt?.fileURL, stateURL)
        XCTAssertEqual(session.text, "mine")
    }

    func testADirtyDocumentWithoutRetentionProofRefusesTheClose() {
        let untitled = DocumentSession(text: "draft")
        second.shownSession = untitled
        untitled.replaceText("draft edited")
        XCTAssertTrue(untitled.isDirty)
        XCTAssertFalse(second.hasCloseRetentionProof(for: untitled))

        secondWindow.performClose(nil)

        XCTAssertTrue(KeyWindowRouter.shared.hasAttachedWindow(second))
        XCTAssertTrue(second.shownSession === untitled)
        XCTAssertEqual(second.presentedError?.title, "Could Not Close Window")
    }

    /// The last window on a root releases it (D1b). The shown conflicted document has an
    /// editor, as it does in production, so the release retires it with its text and conflict
    /// instead of refusing, and the closed app-owned window keeps no prompt.
    func testTheLastRootCloseRetiresAnInstalledConflictedDocumentWithItsState() async throws {
        let root = try makeRoot("blog")
        try await open(primary, root: root)
        primary.openWorkspaceFile(root.appendingPathComponent("a.md"))
        try await waitUntil("window 1 shows a.md") { self.primary.shownSession.fileURL?.lastPathComponent == "a.md" }
        let session = primary.shownSession
        let installation = install(session, in: primary)
        primary.replaceDocumentText("alpha mine", in: session)
        let stateURL = try XCTUnwrap(primary.sessionStateURL(for: session))
        primary.pendingExternalTexts[stateURL] = "alpha theirs"
        primary.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: stateURL)

        firstWindow.performClose(nil)

        XCTAssertFalse(KeyWindowRouter.shared.hasAttachedWindow(primary), "the window closed")
        XCTAssertNil(primary.workspaceRootURL)
        XCTAssertNil(primary.editorBindingInstallations[installation])
        XCTAssertEqual(session.text, "alpha mine", "the unsaved text is kept")
        XCTAssertEqual(primary.pendingExternalTexts[stateURL], "alpha theirs", "the conflict is kept")
        XCTAssertTrue(
            primary.workspaceMutationTerminationSessions().contains { $0 === session },
            "Quit still sees the unsaved document"
        )
        XCTAssertNil(primary.externalChangePrompt, "the closed window keeps no prompt")
        XCTAssertFalse(primary.isSaveBlockedByWindowPrompt(at: stateURL))
    }

    /// A conflicted document that WD8 kept warm when its window closed blocks the last window
    /// on that root, and Show opens it there so the user can resolve it.
    func testAKeptConflictBlocksTheLastRootCloseAndShowOpensIt() async throws {
        let root = try makeRoot("blog")
        try await openPair(root: root)
        second.openWorkspaceFile(root.appendingPathComponent("b.md"))
        try await waitUntil("window 2 shows b.md") { self.second.shownSession.fileURL?.lastPathComponent == "b.md" }
        let kept = second.shownSession
        second.replaceDocumentText("beta mine", in: kept)
        let keptURL = try XCTUnwrap(second.sessionStateURL(for: kept))
        second.pendingExternalTexts[keptURL] = "beta theirs"
        second.externalChangePrompt = AppState.ExternalChangePrompt(fileURL: keptURL)
        secondWindow.performClose(nil)
        XCTAssertFalse(KeyWindowRouter.shared.hasAttachedWindow(second), "WD8 kept the conflict warm")

        firstWindow.performClose(nil)

        XCTAssertTrue(KeyWindowRouter.shared.hasAttachedWindow(primary), "the last window stays open")
        XCTAssertNotNil(primary.workspaceRootURL)
        let refusal = try XCTUnwrap(primary.presentedError)
        XCTAssertEqual(refusal.title, "Could Not Close Window")
        let show = try XCTUnwrap(refusal.showWindow, "the refusal offers to show the blocking file")
        show()
        XCTAssertTrue(primary.shownSession === kept)
        XCTAssertEqual(kept.text, "beta mine")
        XCTAssertEqual(primary.externalChangePrompt?.fileURL, keptURL)
    }

    // MARK: - W7 bullet 4: revoke, writer, and the LRU

    /// After the window leaves `.windowDocuments`, its document no longer keeps the installed
    /// exemption, so the trim counts it (§6.2 step 3). A failed eviction candidate is retained.
    func testClosingRevokesTheInstallationReleasesTheWriterAndTrimsTheLRU() throws {
        let warmURLs = try (0 ..< 8).map { try writeLoose("warm-\($0).md", "warm \($0)") }
        var warm: [DocumentSession] = []
        for url in warmURLs {
            try primary.activateFileSession(url: url)
            warm.append(primary.shownSession)
        }
        // Window 1 moves on, so all eight are countable warm sessions.
        try primary.activateFileSession(url: writeLoose("primary.md", "primary"))
        let blockedOldest = warm[0]
        let blockedURL = try XCTUnwrap(primary.sessionStateURL(for: blockedOldest))
        blockedOldest.replaceText("unsaved oldest")
        primary.detachedSessionURLs.insert(blockedURL)
        try second.activateFileSession(url: writeLoose("shown.md", "shown"))
        let shown = second.shownSession
        let shownStateURL = try XCTUnwrap(second.sessionStateURL(for: shown))
        let binding = second.editorDocumentBinding(for: shown)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        XCTAssertTrue(second.editorBindingInstallations[installation] === shown)
        XCTAssertEqual(second.editorWriterInstallations[ObjectIdentifier(shown)], installation)
        XCTAssertTrue(second.installedSessionURLs().contains(shownStateURL))
        XCTAssertEqual(primary.registry.sessionCache.count, 10, "eight warm plus two shown documents")

        secondWindow.performClose(nil)

        XCTAssertNil(second.editorBindingInstallations[installation], "the installation was revoked")
        XCTAssertNil(second.editorWriterInstallations[ObjectIdentifier(shown)], "the writer was released")
        XCTAssertFalse(second.installedSessionURLs().contains(shownStateURL), "no installed exemption is left")
        XCTAssertTrue(primary.registry.isWarmSession(shown, at: shownStateURL), "the closed document stays warm")
        XCTAssertTrue(
            primary.registry.isWarmSession(blockedOldest, at: blockedURL),
            "the oldest candidate cannot be saved, so it is retained"
        )
        XCTAssertEqual(blockedOldest.text, "unsaved oldest")
        let nextOldestURL = try XCTUnwrap(primary.sessionStateURL(for: warm[1]))
        XCTAssertNil(
            primary.registry.warmSession(at: nextOldestURL),
            "counting the closed document evicted the next countable session"
        )
    }

    // MARK: - The app-owned façade

    /// The next scene gets the app-owned façade back as an empty, admitted window, and pending
    /// external state survives the close on the registry.
    func testClosingTheOwnersWindowLetsTheNextSceneReuseItEmpty() throws {
        KeyWindowRouter.shared.resetForTesting()
        let owner = try XCTUnwrap(primary)
        _ = WindowFacadeHolder(owner: owner)
        let ownerWindow = makeWindow()
        KeyWindowRouter.shared.attach(ownerWindow, to: owner)
        let url = try writeLoose("owned.md", "owned")
        try owner.open(url: url, rememberAsLastOpened: false, preserveWorkspace: false)
        let session = owner.shownSession
        let stateURL = try XCTUnwrap(owner.sessionStateURL(for: session))

        ownerWindow.performClose(nil)

        XCTAssertFalse(owner.registry.connectedWindows.contains { $0 === owner.windowState })
        XCTAssertTrue(owner.isEmptyWorkspaceWindow)
        XCTAssertTrue(owner.registry.isWarmSession(session, at: stateURL))
        XCTAssertTrue(WindowOpenAdmission.admits(owner.windowState))

        let reopened = WindowFacadeHolder(owner: owner)
        XCTAssertTrue(reopened.facade === owner)
        KeyWindowRouter.shared.attach(makeWindow(), to: owner)
        XCTAssertTrue(owner.registry.connectedWindows.contains { $0 === owner.windowState })
        XCTAssertTrue(owner.isEmptyWorkspaceWindow)
        try owner.open(url: url, rememberAsLastOpened: false, preserveWorkspace: false)
        XCTAssertTrue(owner.shownSession === session, "the reopened window adopts the warm session")
    }

    // MARK: - Helpers

    @discardableResult
    private func install(_ session: DocumentSession, in facade: AppState) -> EditorDocumentBindingInstallation {
        let binding = facade.editorDocumentBinding(for: session)
        let installation = EditorDocumentBindingInstallation(
            bindingID: binding.id,
            installationID: EditorDocumentBindingInstallationID()
        )
        binding.onLifecycle(.installed(installation))
        return installation
    }

    private func writeLoose(_ name: String, _ text: String) throws -> URL {
        let folder = directory.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
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
