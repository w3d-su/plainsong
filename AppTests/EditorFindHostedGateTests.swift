import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import SwiftUI
import WebKit
import XCTest

/// Hosted production-path evidence for the Editor Find gates that cannot be closed by
/// AppState-only tests. These tests deliberately do not claim physical keyboard, real IME,
/// or Full Keyboard Access evidence.
@MainActor
final class EditorFindHostedGateTests: XCTestCase {
    func testHostedFindBarSurvivesExternalReloadAndUnmountsAfterMissingFileClose() async throws {
        let fixture = try makeWorkspaceFixture(files: ["post.md": "hit one"])
        let appState = fixture.appState
        appState.setLayoutMode(.sourceOnly)

        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens") {
            appState.currentDocument.fileURL?.lastPathComponent == "post.md"
        }

        let host = makeWorkspaceHost(appState: appState)
        registerTeardown(host: host, fixture: fixture)
        openFindBar(appState, query: "hit")

        try await waitUntil("production find field mounts") {
            self.findQueryField(in: host.window) != nil
                && appState.editorFindHost.controller.session?.total == 1
        }

        let post = fixture.root.appendingPathComponent("post.md")
        try "hit one hit two hit three".write(to: post, atomically: true, encoding: .utf8)
        appState.refreshWorkspaceAfterFileSystemChange()

        try await waitUntil("clean external reload reaches the hosted editor and find counter") {
            appState.currentDocument.text == "hit one hit two hit three"
                && appState.editorFindHost.controller.session?.total == 3
                && self.findQueryField(in: host.window) != nil
        }
        XCTAssertTrue(appState.editorFindHost.ui.isBarVisible)
        XCTAssertEqual(appState.editorFindHost.ui.queryText, "hit")
        XCTAssertNil(appState.editorFindHost.controller.pendingNavigationCommand)

        try FileManager.default.removeItem(at: post)
        appState.refreshWorkspaceAfterFileSystemChange()
        try await waitUntil("missing-file recovery prompt appears") {
            appState.missingFilePrompt?.fileURL.lastPathComponent == "post.md"
        }

        appState.closeMissingFile()
        try await waitUntil("closing the missing file unmounts the production find field") {
            !appState.hasOpenDocument
                && !appState.editorFindHost.ui.isBarVisible
                && self.findQueryField(in: host.window) == nil
        }
        XCTAssertNil(appState.editorFindHost.controller.query)
        XCTAssertNil(appState.editorFindHost.controller.session)
    }

    func testHostedSourcePreviewFindSelectsExactRangeAndScrollsLivePreview() async throws {
        let document = makeLongPreviewDocument()
        let fixture = try makeWorkspaceFixture(files: ["post.md": document.source])
        let appState = fixture.appState
        appState.setLayoutMode(.sourcePreview)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens in source and preview") {
            appState.currentDocument.fileURL?.lastPathComponent == "post.md"
                && appState.isPreviewVisible
        }

        let host = makeWorkspaceHost(appState: appState, width: 1280, height: 760)
        registerTeardown(host: host, fixture: fixture)

        let webView = try await waitForView(WKWebView.self, in: host.window)
        try await waitUntil("live preview renders the target source line", timeout: 8) {
            let value = try await webView.evaluateJavaScript(
                "document.querySelector('[data-line=\"\(document.targetLine)\"]') !== null"
            )
            return value as? Bool == true
        }
        let targetStartsOffscreen = try await webView.evaluateJavaScript(
            """
            (() => {
              const target = document.querySelector('[data-line="\(document.targetLine)"]');
              return window.scrollY === 0 && target.getBoundingClientRect().top >= window.innerHeight;
            })()
            """
        ) as? Bool
        XCTAssertEqual(targetStartsOffscreen, true)

        let sourceBefore = appState.currentDocument.text
        openFindBar(appState, query: document.needle)
        let expectedRange = (document.source as NSString).range(of: document.needle)

        try await waitUntil("production editor applies the exact find selection") {
            EditorSelectionProbe.appliedEditorSelection(in: host.window)?.range == expectedRange
        }
        try await waitUntil("editor selection scrolls the live preview to the matching block") {
            // The existing scroll proxy forwards the editor's first visible source line.
            // `scrollRangeToVisible` only promises that the match becomes visible; it does
            // not promise that the match itself is placed near the top of either viewport.
            let value = try await webView.evaluateJavaScript(
                """
                (() => {
                  const target = document.querySelector('[data-line="\(document.targetLine)"]');
                  const rect = target.getBoundingClientRect();
                  return window.scrollY > 0 && rect.bottom > 0 && rect.top < window.innerHeight;
                })()
                """
            )
            return value as? Bool == true
        }

        XCTAssertEqual(appState.currentDocument.text, sourceBefore)
        XCTAssertEqual(appState.currentDocument.text.utf8.elementsEqual(sourceBefore.utf8), true)
        XCTAssertTrue(appState.isPreviewVisible)
    }

    func testHostedMarkedTextCommandsStayInFindFieldAndDoNotMutateDocument() async throws {
        let fixture = try makeWorkspaceFixture(files: ["post.md": "document source"])
        let appState = fixture.appState
        appState.setLayoutMode(.sourceOnly)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens") { appState.hasOpenDocument }

        let host = makeWorkspaceHost(appState: appState)
        registerTeardown(host: host, fixture: fixture)
        openFindBar(appState, query: "")
        let field = try await waitForFindQueryField(in: host.window)
        XCTAssertTrue(host.window.makeFirstResponder(field))
        let fieldEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let coordinator = try XCTUnwrap(field.delegate as? EditorFindQueryField.Coordinator)
        let sourceBefore = appState.currentDocument.text

        fieldEditor.setMarkedText(
            "ㄅ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(fieldEditor.hasMarkedText())
        XCTAssertFalse(coordinator.control(
            field,
            textView: fieldEditor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        XCTAssertFalse(coordinator.control(
            field,
            textView: fieldEditor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))

        XCTAssertTrue(appState.editorFindHost.ui.isBarVisible)
        XCTAssertEqual(appState.currentDocument.text, sourceBefore)
        XCTAssertTrue(fieldEditor.hasMarkedText())
        fieldEditor.unmarkText()
    }

    func testHostedFindToWorkspaceSearchHandoffCannotBeStolenByOlderFindFocus() async throws {
        let fixture = try makeWorkspaceFixture(files: ["post.md": "alpha"])
        let appState = fixture.appState
        appState.setLayoutMode(.sourceOnly)
        appState.openExternalFile(fixture.root)
        try await waitUntil("workspace document opens") { appState.hasOpenDocument }

        // Keep the host non-key so Find's real key-window-only retry remains pending. Search
        // has the existing designated-window test seam, allowing its newer intent to take a
        // real first responder without adding a Find-only production hook.
        let host = makeWorkspaceHost(appState: appState)
        registerTeardown(host: host, fixture: fixture)
        openFindBar(appState, query: "alpha")
        _ = try await waitForFindQueryField(in: host.window)
        let findRequest = appState.editorFindHost.ui.focusRequestID
        XCTAssertGreaterThan(findRequest, 0)
        XCTAssertNotEqual(appState.editorFindHost.ui.focusAppliedID, findRequest)

        appState.workspaceSearchFocusKeyWindowCheck = { $0 === host.window }
        appState.focusWorkspaceSearch()
        let searchRequest = appState.workspaceSearchUI.focusRequestID

        try await waitUntil("workspace search owns the real hosted field editor") {
            appState.workspaceSearchUI.focusAppliedID == searchRequest
                && WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: host.window)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(appState.editorFindHost.ui.focusSupersededID, findRequest)
        XCTAssertNotEqual(appState.editorFindHost.ui.focusAppliedID, findRequest)
        XCTAssertTrue(WorkspaceSearchFieldFocus.isSearchFieldFirstResponder(in: host.window))
        XCTAssertNotNil(findQueryField(in: host.window), "Find stays open during the focus handoff")
    }
}

@MainActor
private extension EditorFindHostedGateTests {
    private func registerTeardown(host: HostedWorkspace, fixture: WorkspaceFixture) {
        addTeardownBlock { @MainActor in
            let appState = fixture.appState
            let tasks = [appState.autosaveTask, appState.statisticsTask, appState.workspaceReloadTask,
                         appState.workspaceSearchTask, appState.completionWorkspaceTask].compactMap { $0 }
            appState.closeWorkspace()
            if let webView = self.firstDescendant(of: WKWebView.self, in: host.hostingView) {
                webView.stopLoading()
                webView.navigationDelegate = nil
                webView.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
            }
            host.window.makeFirstResponder(nil)
            host.hostingView.rootView = AnyView(EmptyView())
            host.window.contentView = nil
            host.window.close()
            for task in tasks {
                task.cancel()
                await task.value
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            fixture.cleanUp()
        }
    }

    private func openFindBar(_ appState: AppState, query: String) {
        appState.editorFindHost.controller.debounceNanoseconds = 0
        appState.editorFindHost.commandContextOverride = true
        appState.showOrRefocusEditorFind()
        appState.handleEditorFindQueryTextChange(query)
    }

    private func makeWorkspaceHost(
        appState: AppState,
        width: CGFloat = 1000,
        height: CGFloat = 680
    ) -> HostedWorkspace {
        let root = WorkspaceWindow()
            .environmentObject(appState)
            .frame(width: width, height: height)
        let hostingView = NSHostingView(rootView: AnyView(root))
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        return HostedWorkspace(window: window, hostingView: hostingView)
    }

    private func findQueryField(in window: NSWindow) -> NSTextField? {
        firstDescendant(of: NSTextField.self, in: window.contentView) {
            $0.accessibilityIdentifier() == EditorFindAccessibility.queryField
        }
    }

    private func waitForFindQueryField(in window: NSWindow) async throws -> NSTextField {
        try await waitUntil("production find field mounts") {
            self.findQueryField(in: window) != nil
        }
        return try XCTUnwrap(findQueryField(in: window))
    }

    private func waitForView<View: NSView>(
        _ type: View.Type,
        in window: NSWindow
    ) async throws -> View {
        try await waitUntil("\(View.self) mounts in production WorkspaceWindow") {
            self.firstDescendant(of: type, in: window.contentView) != nil
        }
        return try XCTUnwrap(firstDescendant(of: type, in: window.contentView))
    }

    private func firstDescendant<View: NSView>(
        of type: View.Type,
        in root: NSView?,
        where predicate: (View) -> Bool = { _ in true }
    ) -> View? {
        guard let root else { return nil }
        if let match = root as? View, predicate(match) {
            return match
        }
        for child in root.subviews {
            if let match = firstDescendant(of: type, in: child, where: predicate) {
                return match
            }
        }
        return nil
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        predicate: @escaping @MainActor () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func makeWorkspaceFixture(files: [String: String]) throws -> WorkspaceFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorFindHostedGates")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        let suiteName = "EditorFindHostedGateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let appState = AppState(
            lastOpenedFileStore: MemoryLastOpenedFileStore(),
            recentItemStore: MemoryRecentItemStore(),
            shouldRestoreLastOpenedFile: false,
            userDefaults: defaults
        )
        return WorkspaceFixture(
            root: root,
            appState: appState,
            defaults: defaults,
            defaultsSuiteName: suiteName
        )
    }

    private func makeLongPreviewDocument() -> LongPreviewDocument {
        let needle = "PLAINSONG_HOSTED_FIND_TARGET"
        var lines = ["# Hosted preview"]
        lines += (1 ... 180).flatMap { ["Paragraph before \($0)", ""] }
        let targetLine = lines.count + 1
        lines.append(needle)
        lines.append("")
        lines += (1 ... 180).flatMap { ["Paragraph after \($0)", ""] }
        return LongPreviewDocument(source: lines.joined(separator: "\n"), needle: needle, targetLine: targetLine)
    }
}

private struct HostedWorkspace {
    let window: NSWindow
    let hostingView: NSHostingView<AnyView>
}

private struct LongPreviewDocument {
    let source: String
    let needle: String
    let targetLine: Int
}

@MainActor
private struct WorkspaceFixture {
    let root: URL
    let appState: AppState
    let defaults: UserDefaults
    let defaultsSuiteName: String

    func cleanUp() {
        appState.workspaceSearchFocusKeyWindowCheck = nil
        appState.workspaceSearchTask?.cancel()
        appState.workspaceReloadTask?.cancel()
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class MemoryLastOpenedFileStore: LastOpenedFilePersisting {
    private var storedURL: URL?

    func save(_ url: URL) throws {
        storedURL = url
    }

    func restore() throws -> URL? {
        storedURL
    }
}

private final class MemoryRecentItemStore: RecentItemPersisting {
    private var storedURLs: [URL] = []

    func save(_ url: URL) throws {
        storedURLs.removeAll { $0 == url }
        storedURLs.insert(url, at: 0)
    }

    func restore() throws -> [URL] {
        storedURLs
    }
}
