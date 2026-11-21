import AppKit
import MarkdownCore
@testable import Plainsong
import XCTest

/// Windows PR D2, W8 bullet 1 ("none is left blank"): a scene that took a request but whose
/// window attached only after the request expired (`WorkspaceWindowRequests`).
@MainActor
final class WindowLateSceneAppTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var directory: URL!
    private var primary: AppState!
    private var scenes: [WindowFacadeHolder] = []
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        KeyWindowRouter.shared.resetForTesting()
        suiteName = "WindowLateScene-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        primary = AppState(
            lastOpenedFileStore: MemoryLastOpenedFileStore(),
            recentItemStore: MemoryRecentItemStore(),
            workspaceSearchDebounceNanoseconds: 0,
            shouldRestoreLastOpenedFile: false,
            userDefaults: defaults
        )
        WorkspaceSceneReopener.shared.remember(primary)
        // The scene appears only when a test builds it, as a slow SwiftUI scene would.
        WorkspaceSceneReopener.shared.installOpenScene {}
        // The launch scene shows the owner.
        KeyWindowRouter.shared.attach(makeWindow(), to: makeScene().facade)
    }

    override func tearDown() async throws {
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

    /// The open does not run late, so the window would stay blank: it closes.
    func testAWindowThatAttachesAfterItsOpenExpiredClosesInsteadOfStayingBlank() async throws {
        try primary.open(url: write("A.md", "alpha"), rememberAsLastOpened: false, preserveWorkspace: false)

        try primary.routeOpen(write("B.md", "beta"))
        let late = makeScene().facade
        WorkspaceWindowRequests.shared.expireAllForTesting()
        XCTAssertEqual(primary.presentedError?.title, "Could Not Open File")

        KeyWindowRouter.shared.attach(makeWindow(), to: late)

        try await waitUntil("the late blank window closes") {
            !KeyWindowRouter.shared.hasAttachedWindow(late)
        }
        XCTAssertTrue(late.isEmptyWorkspaceWindow, "the expired open does not run later")
        XCTAssertEqual(primary.shownSession.text, "alpha")
    }

    /// Something opened in the late window before it could close: it stays.
    func testALateWindowThatIsNoLongerEmptyStays() async throws {
        try primary.open(url: write("A.md", "alpha"), rememberAsLastOpened: false, preserveWorkspace: false)

        try primary.routeOpen(write("B.md", "beta"))
        let late = makeScene().facade
        WorkspaceWindowRequests.shared.expireAllForTesting()

        KeyWindowRouter.shared.attach(makeWindow(), to: late)
        try late.open(url: write("C.md", "gamma"), rememberAsLastOpened: false, preserveWorkspace: false)
        await settle()

        XCTAssertTrue(KeyWindowRouter.shared.hasAttachedWindow(late))
        XCTAssertEqual(late.shownSession.text, "gamma")
    }

    /// File › New Window asked for an empty window, so a late one stays.
    func testANewWindowThatAttachesAfterItsRequestExpiredStays() async {
        XCTAssertTrue(WorkspaceWindowRequests.shared.openNewWindow(on: primary.registry))
        let late = makeScene().facade
        WorkspaceWindowRequests.shared.expireAllForTesting()

        KeyWindowRouter.shared.attach(makeWindow(), to: late)
        await settle()

        XCTAssertTrue(KeyWindowRouter.shared.hasAttachedWindow(late))
    }

    // MARK: - Fixture

    private func makeScene() -> WindowFacadeHolder {
        let scene = WindowFacadeHolder(owner: primary)
        scenes.append(scene)
        return scene
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

    /// Lets the deferred close decision run.
    private func settle() async {
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
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
