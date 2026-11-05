import AppKit
import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// Windows PR D2: File › New Window and the §5.2 Open rule (WD3, WD7, §4.3 and W6 bullet 8b,
/// W8). Scenes are simulated: the installed opener builds a `WindowFacadeHolder` the way
/// SwiftUI's `WindowGroup` does and attaches its window.
@MainActor
final class WindowOpenRoutingAppTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var directory: URL!
    private var primary: AppState!
    private var lastOpened: MemoryLastOpenedFileStore!
    private var scenes: [WindowFacadeHolder] = []
    private var windows: [NSWindow] = []
    private var sceneRequests = 0
    /// When false, the opener records the request but no scene appears until `attachNextScene`.
    private var attachesScenesImmediately = true
    private var pendingScenes = 0

    override func setUp() async throws {
        KeyWindowRouter.shared.resetForTesting()
        WindowOpenAdmission.testingBypass = true
        suiteName = "WindowOpenRouting-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lastOpened = MemoryLastOpenedFileStore()
        primary = AppState(
            lastOpenedFileStore: lastOpened,
            recentItemStore: MemoryRecentItemStore(),
            workspaceSearchDebounceNanoseconds: 0,
            shouldRestoreLastOpenedFile: true,
            userDefaults: defaults
        )
        WorkspaceSceneReopener.shared.remember(primary)
        WorkspaceSceneReopener.shared.installOpenScene { [weak self] in
            self?.sceneRequested()
        }
        // The launch scene shows the owner.
        attachScene()
    }

    override func tearDown() async throws {
        for scene in scenes {
            scene.facade.workspaceWatcher?.stop()
        }
        for window in windows {
            window.orderOut(nil)
        }
        windows = []
        scenes = []
        primary = nil
        KeyWindowRouter.shared.resetForTesting()
        WindowOpenAdmission.resetForTesting()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - New Window (WD3, W8 bullet 2)

    func testNewWindowOpensAnEmptyAdmittedWindowThatDoesNotRestore() throws {
        let file = try write("A.md", "alpha")
        try primary.open(url: file, rememberAsLastOpened: false, preserveWorkspace: false)
        try lastOpened.save(try write("B.md", "beta"))

        XCTAssertTrue(WorkspaceWindowRequests.shared.openNewWindow(on: primary.registry))

        XCTAssertEqual(sceneRequests, 1)
        let window = try XCTUnwrap(scenes.last?.facade)
        XCTAssertFalse(window === primary)
        XCTAssertTrue(window.isEmptyWorkspaceWindow)
        XCTAssertTrue(WindowOpenAdmission.admits(window.windowState))
        XCTAssertTrue(primary.registry.connectedWindows.contains { $0 === window.windowState })
        // Only the launch window restores, once (§6.1).
        XCTAssertFalse(window.didAttemptRestore)
        window.restoreLastOpenedFileIfNeeded()
        XCTAssertTrue(window.isEmptyWorkspaceWindow, "a new window does not restore")
        XCTAssertFalse(window.didAttemptRestore)
        XCTAssertEqual(primary.shownSession.text, "alpha")
    }

    func testNewFileInTheKeyWindowsRootCreatesTheFileThere() async throws {
        let root = try makeRoot("blog", files: ["a.md": "alpha"])
        try await openRoot(root, in: primary)
        KeyWindowRouter.shared.testingPin = primary

        primary.newFile()

        try await waitUntil("Untitled.md opens in the key window") {
            self.primary.shownSession.fileURL?.lastPathComponent == "Untitled.md"
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Untitled.md").path))
        XCTAssertEqual(sceneRequests, 0)
    }

    // MARK: - WD7: an empty target takes the open, otherwise a new window does

    func testFinderOpenReusesAnEmptyFrontmostWindow() throws {
        let alpha = try write("A.md", "alpha")
        let beta = try write("B.md", "beta")
        try primary.open(url: alpha, rememberAsLastOpened: false, preserveWorkspace: false)
        let empty = try openNewWindow()
        bringToFront(empty)

        primary.openExternalFile(beta)

        XCTAssertEqual(empty.shownSession.text, "beta")
        XCTAssertEqual(primary.shownSession.text, "alpha")
        XCTAssertEqual(sceneRequests, 1, "only the New Window above asked for a scene")
    }

    func testFinderOpenWithANonEmptyFrontmostWindowOpensANewWindow() throws {
        let alpha = try write("A.md", "alpha")
        let beta = try write("B.md", "beta")
        try primary.open(url: alpha, rememberAsLastOpened: false, preserveWorkspace: false)
        bringToFront(primary)

        primary.openExternalFile(beta)

        XCTAssertEqual(sceneRequests, 1)
        let opened = try XCTUnwrap(scenes.last?.facade)
        XCTAssertFalse(opened === primary)
        XCTAssertEqual(opened.shownSession.text, "beta")
        XCTAssertEqual(primary.shownSession.text, "alpha")
        XCTAssertNil(primary.presentedError)
        XCTAssertNil(opened.presentedError)
    }

    func testOpenRecentFromANonEmptyKeyWindowOpensANewWindow() throws {
        let alpha = try write("A.md", "alpha")
        let beta = try write("B.md", "beta")
        try primary.open(url: alpha, rememberAsLastOpened: false, preserveWorkspace: false)
        KeyWindowRouter.shared.testingPin = primary

        WorkspaceSceneReopener.shared.performFileCommand(openScene: { [weak self] in
            // The menu installs the same `openWindow` that New Window and WD7 use.
            self?.sceneRequested()
        }, action: { $0.routeOpen(beta) })

        XCTAssertEqual(sceneRequests, 1)
        let opened = try XCTUnwrap(scenes.last?.facade)
        XCTAssertFalse(opened === primary)
        XCTAssertEqual(opened.shownSession.text, "beta")
        XCTAssertEqual(primary.shownSession.text, "alpha")
    }

    func testOpeningAnOpenRootAgainOpensANewWindowOnTheSharedContext() async throws {
        let root = try makeRoot("blog", files: ["a.md": "alpha"])
        try await openRoot(root, in: primary)

        primary.routeOpen(root)

        let opened = try XCTUnwrap(scenes.last?.facade)
        XCTAssertFalse(opened === primary)
        try await waitUntil("the new window shares the root") { opened.workspaceTree != nil }
        XCTAssertTrue(opened.workspaceRootContext === primary.workspaceRootContext)
        XCTAssertNotNil(primary.workspaceRootURL, "the first window keeps its root")
    }

    func testAnOverlappingRootIsRefusedBeforeAWindowAppears() async throws {
        let root = try makeRoot("blog", files: ["posts/a.md": "alpha"])
        try await openRoot(root, in: primary)

        primary.routeOpen(root.appendingPathComponent("posts", isDirectory: true))

        XCTAssertEqual(sceneRequests, 0)
        XCTAssertEqual(scenes.count, 1)
        XCTAssertNotNil(primary.presentedError?.showWindow, "the refusal offers to show the other window")
        XCTAssertEqual(primary.workspaceRootURL?.lastPathComponent, "blog")
    }

    /// No blank window is left behind when the open fails in the window it asked for.
    func testAFailedOpenInTheNewWindowClosesItAndReportsInTheRequestingWindow() throws {
        let alpha = try write("A.md", "alpha")
        let beta = try write("B.md", "beta")
        try primary.open(url: alpha, rememberAsLastOpened: false, preserveWorkspace: false)
        bringToFront(primary)
        attachesScenesImmediately = false

        primary.routeOpen(beta)
        XCTAssertEqual(sceneRequests, 1)
        try FileManager.default.removeItem(at: beta)
        let opened = attachNextScene()

        XCTAssertFalse(KeyWindowRouter.shared.hasAttachedWindow(opened), "the blank window closed")
        XCTAssertFalse(primary.registry.connectedWindows.contains { $0 === opened.windowState })
        XCTAssertEqual(primary.presentedError?.title, "Could Not Open File")
        XCTAssertEqual(primary.shownSession.text, "alpha")
    }

    /// A request belongs to its registry: a scene of another registry cannot take it.
    func testARequestRunsOnlyInASceneOfItsRegistry() throws {
        let beta = try write("B.md", "beta")
        try primary.open(url: try write("A.md", "alpha"), rememberAsLastOpened: false, preserveWorkspace: false)
        attachesScenesImmediately = false
        primary.routeOpen(beta)

        let foreign = AppState(shouldRestoreLastOpenedFile: false, userDefaults: defaults)
        let foreignScene = WindowFacadeHolder(owner: foreign)
        KeyWindowRouter.shared.attach(makeWindow(), to: foreignScene.facade)
        XCTAssertNil(foreignScene.facade.shownSession.fileURL)

        let opened = attachNextScene()
        XCTAssertEqual(opened.shownSession.text, "beta")
    }

    // MARK: - §4.3 and W6 bullet 8b: a single file inside an open root

    func testAFileInsideAnOpenRootOpensAsThatRootsDocumentInANewWindow() async throws {
        let root = try makeRoot("blog", files: ["a.md": "alpha", "b.md": "beta"])
        try await openRoot(root, in: primary)
        primary.openWorkspaceFile(root.appendingPathComponent("a.md"))
        try await waitUntil("window 1 shows a.md") { self.primary.shownSession.text == "alpha" }
        bringToFront(primary)

        primary.openExternalFile(root.appendingPathComponent("b.md"))

        let opened = try XCTUnwrap(scenes.last?.facade)
        XCTAssertFalse(opened === primary)
        XCTAssertEqual(opened.shownSession.text, "beta")
        XCTAssertTrue(opened.workspaceRootContext === primary.workspaceRootContext)
        let binding = try XCTUnwrap(opened.anchoredSessionFileBinding(for: opened.shownSession))
        XCTAssertEqual(binding.location.rootAuthority, primary.workspaceSearchRootAuthority)
        XCTAssertEqual(primary.shownSession.text, "alpha")
    }

    func testAFileInsideAnOpenRootReusesAnEmptyFrontmostWindow() async throws {
        let root = try makeRoot("blog", files: ["a.md": "alpha", "b.md": "beta"])
        try await openRoot(root, in: primary)
        primary.openWorkspaceFile(root.appendingPathComponent("a.md"))
        try await waitUntil("window 1 shows a.md") { self.primary.shownSession.text == "alpha" }
        let empty = try openNewWindow()
        bringToFront(empty)

        primary.openExternalFile(root.appendingPathComponent("b.md"))

        XCTAssertEqual(empty.shownSession.text, "beta")
        XCTAssertTrue(empty.workspaceRootContext === primary.workspaceRootContext)
        XCTAssertNotNil(empty.anchoredSessionFileBinding(for: empty.shownSession))
        XCTAssertEqual(sceneRequests, 1)
    }

    func testAFileInsideAnOpenRootThatAWindowShowsFocusesThatWindow() async throws {
        let root = try makeRoot("blog", files: ["a.md": "alpha"])
        try await openRoot(root, in: primary)
        primary.openWorkspaceFile(root.appendingPathComponent("a.md"))
        try await waitUntil("window 1 shows a.md") { self.primary.shownSession.text == "alpha" }
        let empty = try openNewWindow()
        bringToFront(empty)

        primary.openExternalFile(root.appendingPathComponent("a.md"))

        XCTAssertTrue(KeyWindowRouter.shared.focusedWindowState === primary.windowState)
        XCTAssertTrue(empty.isEmptyWorkspaceWindow)
        XCTAssertEqual(sceneRequests, 1)
    }

    // MARK: - WD1 for New File's save panel

    func testNewFileOverAFileAnotherWindowShowsFocusesItAndWritesNothing() throws {
        let alpha = try write("A.md", "alpha")
        try primary.open(url: alpha, rememberAsLastOpened: false, preserveWorkspace: false)
        let other = try openNewWindow()

        other.createNewFile(at: alpha)

        XCTAssertTrue(KeyWindowRouter.shared.focusedWindowState === primary.windowState)
        XCTAssertEqual(try String(contentsOf: alpha, encoding: .utf8), "alpha")
        XCTAssertTrue(other.isEmptyWorkspaceWindow)
        XCTAssertNil(other.presentedError)
    }

    // MARK: - Helpers

    private func sceneRequested() {
        sceneRequests += 1
        if attachesScenesImmediately {
            attachScene()
        } else {
            pendingScenes += 1
        }
    }

    @discardableResult
    private func attachScene() -> AppState {
        let scene = WindowFacadeHolder(owner: primary)
        scenes.append(scene)
        KeyWindowRouter.shared.attach(makeWindow(), to: scene.facade)
        return scene.facade
    }

    private func attachNextScene() -> AppState {
        XCTAssertGreaterThan(pendingScenes, 0)
        pendingScenes -= 1
        return attachScene()
    }

    private func openNewWindow() throws -> AppState {
        let before = scenes.count
        XCTAssertTrue(WorkspaceWindowRequests.shared.openNewWindow(on: primary.registry))
        XCTAssertEqual(scenes.count, before + 1)
        return try XCTUnwrap(scenes.last?.facade)
    }

    private func bringToFront(_ facade: AppState) {
        for window in windows where KeyWindowRouter.shared.facade(for: window) != nil {
            window.orderFront(nil)
        }
        let target = windows.first { KeyWindowRouter.shared.facade(for: $0) === facade }
        target?.orderFront(nil)
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

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func makeRoot(_ name: String, files: [String: String]) throws -> URL {
        let root = directory.appendingPathComponent(name, isDirectory: true)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    private func openRoot(_ root: URL, in facade: AppState) async throws {
        try facade.openWorkspace(url: root, rememberAsLastOpened: false)
        await facade.workspaceReloadTask?.value
        try await waitUntil("the root installs") {
            facade.workspaceInstalledCaptureGeneration == facade.workspaceGeneration
                && facade.workspaceTree != nil
        }
        facade.workspaceWatcher?.stop()
    }

    private func waitUntil(_ description: String, condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
        throw CocoaError(.userCancelled)
    }
}
