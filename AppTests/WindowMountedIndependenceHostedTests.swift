import AppKit
@testable import EditorKit
import MarkdownCore
@testable import Plainsong
@testable import PreviewKit
import SwiftUI
import WebKit
import XCTest

/// Windows PR D2, W2 bullets 1–3 and W7 bullet 5: two production `WorkspaceWindow`s, each on
/// its own `AppState` façade and `WindowState`, mounted in real `NSWindow`s.
@MainActor
extension EditorFindHostedGateTests {
    func testTwoMountedWindowsOnOneRootKeepIndependentDocumentsAndChrome() async throws {
        let alpha = Self.longDocument(marker: "ALPHA")
        let beta = Self.longDocument(marker: "BETA")
        let fixture = try makeWorkspaceFixture(files: ["A.md": alpha, "B.md": beta, "C.md": "# CHARLIE\n"])
        let primary = fixture.appState
        let second = primary.makeSiblingFacade(admitsFileOperations: true)
        registerSiblingTeardown(second)
        try await openRoot(fixture.root, in: primary)
        try second.openWorkspace(url: fixture.root, rememberAsLastOpened: false)
        try await waitUntil("window 2 shares the root") { second.workspaceTree != nil }
        XCTAssertTrue(primary.workspaceRootContext === second.workspaceRootContext)
        try await show("A.md", in: primary, root: fixture.root)
        try await show("B.md", in: second, root: fixture.root)

        let (first, other) = try await mountPair(primary: primary, second: second, fixture: fixture)
        try await assertIndependent(
            first: first, primary: primary, firstMarker: "ALPHA",
            other: other, second: second, otherMarker: "BETA"
        )

        // Switching the document in window 1 leaves window 2 untouched.
        let otherSelection = appliedRange(in: other.window)
        let otherVisible = EditorSelectionProbe.visibleTextRange(in: other.window)
        primary.openWorkspaceFile(fixture.root.appendingPathComponent("C.md"))
        try await waitUntil("window 1 shows C.md") {
            self.editorTextView(in: first.window)?.text?.contains("CHARLIE") == true
        }
        XCTAssertTrue(editorTextView(in: other.window)?.text?.contains("BETA") == true)
        XCTAssertEqual(appliedRange(in: other.window), otherSelection)
        XCTAssertEqual(EditorSelectionProbe.visibleTextRange(in: other.window), otherVisible)
        XCTAssertEqual(other.window.representedURL?.lastPathComponent, "B.md")
        let otherPreview = try XCTUnwrap(other.preview)
        let otherText = try await previewText(otherPreview)
        XCTAssertTrue(otherText.contains("BETA"))
        XCTAssertFalse(otherText.contains("CHARLIE"))
    }

    func testTwoMountedWindowsOnTwoRootsKeepIndependentDocumentsAndChrome() async throws {
        let fixture = try makeWorkspaceFixture(files: [
            "one/A.md": Self.longDocument(marker: "ALPHA"),
            "two/B.md": Self.longDocument(marker: "BETA"),
        ])
        let primary = fixture.appState
        let second = primary.makeSiblingFacade(admitsFileOperations: true)
        registerSiblingTeardown(second)
        let rootA = fixture.root.appendingPathComponent("one", isDirectory: true)
        let rootB = fixture.root.appendingPathComponent("two", isDirectory: true)
        try await openRoot(rootA, in: primary)
        try await openRoot(rootB, in: second)
        XCTAssertFalse(primary.workspaceRootContext === second.workspaceRootContext)
        try await show("A.md", in: primary, root: rootA)
        try await show("B.md", in: second, root: rootB)

        let (first, other) = try await mountPair(primary: primary, second: second, fixture: fixture)
        try await assertIndependent(
            first: first, primary: primary, firstMarker: "ALPHA",
            other: other, second: second, otherMarker: "BETA"
        )
        XCTAssertNotEqual(primary.workspaceRootURL, second.workspaceRootURL)
    }

    /// W2 bullet 3: an external change to A.md shows its banner only in the window showing it.
    func testAnExternalChangeShowsItsBannerOnlyInTheWindowShowingTheFile() async throws {
        let fixture = try makeWorkspaceFixture(files: ["A.md": "alpha on disk\n", "B.md": "beta on disk\n"])
        let primary = fixture.appState
        let second = primary.makeSiblingFacade(admitsFileOperations: true)
        registerSiblingTeardown(second)
        try await openRoot(fixture.root, in: primary, keepWatcher: true)
        try second.openWorkspace(url: fixture.root, rememberAsLastOpened: false)
        try await waitUntil("window 2 shares the root") { second.workspaceTree != nil }
        try await show("A.md", in: primary, root: fixture.root)
        try await show("B.md", in: second, root: fixture.root)
        let (first, other) = try await mountPair(primary: primary, second: second, fixture: fixture)

        primary.replaceDocumentText("alpha edited here\n", in: primary.shownSession)
        try Data("alpha changed on disk\n".utf8).write(to: fixture.root.appendingPathComponent("A.md"))

        try await waitUntil("window 1 shows the banner", timeout: 10) {
            primary.externalChangePrompt != nil
                && AccessibilityQuery.find(identifier: nil, label: "Reload", onlyIn: first.window) != nil
        }
        XCTAssertNil(second.externalChangePrompt)
        XCTAssertNil(AccessibilityQuery.find(identifier: nil, label: "Reload", onlyIn: other.window))
        XCTAssertFalse(primary.canSave)
        XCTAssertTrue(second.canSave)
    }

    /// W7 bullet 5: closing a window invalidates its preview controller, which is then
    /// released with the window's views.
    func testClosingAWindowInvalidatesAndReleasesItsPreview() async throws {
        let fixture = try makeWorkspaceFixture(files: ["A.md": "# Alpha\n", "B.md": "# Beta\n"])
        let primary = fixture.appState
        let second = primary.makeSiblingFacade(admitsFileOperations: true)
        registerSiblingTeardown(second)
        try await openRoot(fixture.root, in: primary)
        try second.openWorkspace(url: fixture.root, rememberAsLastOpened: false)
        try await waitUntil("window 2 shares the root") { second.workspaceTree != nil }
        try await show("A.md", in: primary, root: fixture.root)
        try await show("B.md", in: second, root: fixture.root)
        let (_, other) = try await mountPair(primary: primary, second: second, fixture: fixture)
        weak var controller = other.preview
        XCTAssertNotNil(controller)
        XCTAssertEqual(WindowPreviewControllers.controllers(for: second.windowState).count, 1)

        other.window.performClose(nil)

        XCTAssertFalse(KeyWindowRouter.shared.hasAttachedWindow(second))
        XCTAssertTrue(controller?.isInvalidated ?? true, "the closed window's preview was invalidated")
        XCTAssertTrue(WindowPreviewControllers.controllers(for: second.windowState).isEmpty)
        other.host.hostingView.rootView = AnyView(EmptyView())
        other.host.hostingView.layoutSubtreeIfNeeded()
        other.window.contentView = nil
        try await waitUntil("the closed window's preview is released") { controller == nil }
    }

    // MARK: - Helpers

    @MainActor
    struct MountedWorkspaceWindow {
        let window: DesignatedKeyWindow
        let host: HostedWorkspace
        var preview: PreviewController? {
            host.previewLifecycle.controllerForShutdown
        }
    }

    private static func longDocument(marker: String) -> String {
        (["# \(marker)"] + (1 ... 160).flatMap { ["\(marker) paragraph \($0)", ""] }).joined(separator: "\n")
    }

    private func registerSiblingTeardown(_ second: AppState) {
        addTeardownBlock { @MainActor in
            let tasks = self.activeTasks(in: second)
            tasks.forEach { $0.cancel() }
            second.workspaceWatcher?.stop()
            second.closeWorkspace()
            for task in tasks {
                await task.value
            }
            second.workspaceSearchFocusKeyWindowCheck = nil
            KeyWindowRouter.shared.resetForTesting()
            WindowOpenAdmission.resetForTesting()
        }
    }

    private func openRoot(_ root: URL, in facade: AppState, keepWatcher: Bool = false) async throws {
        try facade.openWorkspace(url: root, rememberAsLastOpened: false)
        try await waitUntil("\(root.lastPathComponent) installs") {
            facade.workspaceInstalledCaptureGeneration == facade.workspaceGeneration
                && facade.workspaceSearchRootAuthority != nil
                && facade.workspaceTree != nil
        }
        if !keepWatcher {
            facade.workspaceWatcher?.stop()
        }
    }

    private func show(_ name: String, in facade: AppState, root: URL) async throws {
        facade.openWorkspaceFile(root.appendingPathComponent(name))
        try await waitUntil("\(name) opens") { facade.shownSession.fileURL?.lastPathComponent == name }
        XCTAssertNil(facade.presentedError)
        facade.storeLayoutMode(.sourcePreview)
    }

    private func mountPair(
        primary: AppState,
        second: AppState,
        fixture: WorkspaceFixture
    ) async throws -> (MountedWorkspaceWindow, MountedWorkspaceWindow) {
        let group = makeHostedWorkspaceGroup(fixture: fixture)
        let firstWindow = mountDesignatedKeyWorkspace(in: group, appState: primary)
        let otherWindow = mountDesignatedKeyWorkspace(in: group, appState: second, originX: 1040)
        let first = MountedWorkspaceWindow(window: firstWindow, host: try XCTUnwrap(group.members.first?.host))
        let other = MountedWorkspaceWindow(window: otherWindow, host: try XCTUnwrap(group.members.last?.host))
        try await waitUntil("both windows attach to their own façade") {
            KeyWindowRouter.shared.facade(for: firstWindow) === primary
                && KeyWindowRouter.shared.facade(for: otherWindow) === second
        }
        designateKeyWindow(firstWindow, in: group)
        for (mounted, facade) in [(first, primary), (other, second)] {
            try await waitUntil("\(facade.shownSession.fileURL?.lastPathComponent ?? "?") installs its editor", timeout: 20) {
                guard let applied = EditorSelectionProbe.appliedEditorSelection(in: mounted.window) else { return false }
                return applied.isDocumentInstalled
                    && applied.documentIdentity == facade.editorDocumentIdentity(for: facade.shownSession)
            }
            XCTAssertTrue(mounted.preview?.webView.window === mounted.window, "each window owns its preview")
        }
        return (first, other)
    }

    private func assertIndependent(
        first: MountedWorkspaceWindow, primary: AppState, firstMarker: String,
        other: MountedWorkspaceWindow, second: AppState, otherMarker: String
    ) async throws {
        // Editor text.
        let firstEditor = try XCTUnwrap(editorTextView(in: first.window))
        let otherEditor = try XCTUnwrap(editorTextView(in: other.window))
        XCTAssertTrue(firstEditor.text?.contains(firstMarker) == true)
        XCTAssertFalse(firstEditor.text?.contains(otherMarker) == true)
        XCTAssertTrue(otherEditor.text?.contains(otherMarker) == true)
        XCTAssertFalse(firstEditor === otherEditor)

        // Preview render.
        let firstPreview = try XCTUnwrap(first.preview)
        let otherPreview = try XCTUnwrap(other.preview)
        XCTAssertFalse(firstPreview === otherPreview)
        try await waitUntil("each preview renders its own document", timeout: 15) {
            let firstText = (try? await self.previewText(firstPreview)) ?? ""
            let otherText = (try? await self.previewText(otherPreview)) ?? ""
            return firstText.contains(firstMarker) && !firstText.contains(otherMarker)
                && otherText.contains(otherMarker) && !otherText.contains(firstMarker)
        }

        // Title, proxy icon, and file header.
        XCTAssertEqual(first.window.representedURL?.lastPathComponent, primary.shownSession.fileURL?.lastPathComponent)
        XCTAssertEqual(other.window.representedURL?.lastPathComponent, second.shownSession.fileURL?.lastPathComponent)
        XCTAssertNotEqual(first.window.title, other.window.title, "each window titles its own document")
        let firstHeader = AccessibilityQuery.find(identifier: "plainsong.editor.fileName", label: nil, onlyIn: first.window)
            .flatMap(AccessibilityQuery.value(of:))
        let otherHeader = AccessibilityQuery.find(identifier: "plainsong.editor.fileName", label: nil, onlyIn: other.window)
            .flatMap(AccessibilityQuery.value(of:))
        XCTAssertEqual(firstHeader, primary.shownSession.fileURL?.lastPathComponent)
        XCTAssertEqual(otherHeader, second.shownSession.fileURL?.lastPathComponent)

        // Selection and editor scroll.
        let otherSelectionBefore = appliedRange(in: other.window)
        let otherVisibleBefore = EditorSelectionProbe.visibleTextRange(in: other.window)
        let firstLength = (firstEditor.text ?? "").utf16.count
        firstEditor.textSelection = NSRange(location: firstLength - 5, length: 3)
        firstEditor.scrollRangeToVisible(NSRange(location: firstLength - 1, length: 0))
        try await waitUntil("window 1's selection and scroll apply") {
            self.appliedRange(in: first.window) == NSRange(location: firstLength - 5, length: 3)
                && (EditorSelectionProbe.visibleTextRange(in: first.window)?.location ?? 0) > 0
        }
        XCTAssertEqual(appliedRange(in: other.window), otherSelectionBefore)
        XCTAssertEqual(EditorSelectionProbe.visibleTextRange(in: other.window), otherVisibleBefore)

        // Preview scroll.
        _ = try await firstPreview.webView.evaluateJavaScript("window.scrollTo(0, 600); window.scrollY")
        let otherScroll = try await otherPreview.webView.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(otherScroll ?? 0, 0, accuracy: 0.5)

        // Find visibility and query.
        openFindBar(primary, query: firstMarker)
        _ = try await waitForFindQueryField(in: first.window)
        XCTAssertNil(findQueryField(in: other.window), "window 2's Find bar stays closed")
        XCTAssertFalse(second.editorFindHost.ui.isBarVisible)
        XCTAssertEqual(second.editorFindHost.ui.queryText, "")

        // Search mode and results.
        second.updateWorkspaceSearchQueryText(otherMarker)
        XCTAssertEqual(second.workspaceSearchUI.queryText, otherMarker)
        XCTAssertEqual(primary.workspaceSearchUI.queryText, "")

        // Banners.
        XCTAssertNil(primary.externalChangePrompt)
        XCTAssertNil(second.externalChangePrompt)

        // Layout.
        second.storeLayoutMode(.sourceOnly)
        try await waitUntil("window 2 hides its preview") { self.layoutFrame("preview", in: other.window) == nil }
        XCTAssertNotNil(layoutFrame("preview", in: first.window), "window 1 keeps its preview")
        XCTAssertEqual(primary.layoutMode, .sourcePreview)
    }

    private func previewText(_ controller: PreviewController) async throws -> String {
        try await controller.webView.evaluateJavaScript("document.body.innerText") as? String ?? ""
    }
}
