import AppKit
@testable import EditorKit
import Foundation
@testable import Plainsong
@testable import PreviewKit
import SwiftUI
import WebKit
import XCTest

@MainActor
extension EditorFindHostedGateTests {
    func registerTeardown(host: HostedWorkspace, fixture: WorkspaceFixture) {
        addTeardownBlock { @MainActor in
            let appState = fixture.appState
            let tasks = self.activeTasks(in: appState)
            tasks.forEach { $0.cancel() }
            var previewController = host.previewLifecycle.controllerForShutdown
            XCTAssertNotNil(previewController, "Hosted workspace did not expose its preview controller")
            previewController?.shutdownForTesting()
            host.window.makeFirstResponder(nil)
            host.hostingView.rootView = AnyView(EmptyView())
            host.hostingView.layoutSubtreeIfNeeded()
            await self.fulfillment(of: [host.disposal.expectation], timeout: 2)
            XCTAssertTrue(host.disposal.didDisappear, "Hosted root did not report disappearance")
            previewController = nil
            try await self.waitUntil("hosted PreviewController and WKWebView deallocate") {
                host.previewLifecycle.isReleased
            }
            host.window.contentView = nil
            host.window.orderOut(nil)
            host.window.close()
            appState.closeWorkspace()
            for task in tasks {
                await task.value
            }
            #if DEBUG
                EditorPreviewScrollCoordinator.latestDebugInstance = nil
            #endif
            fixture.cleanUp()
        }
    }

    func activeTasks(in appState: AppState) -> [Task<Void, Never>] {
        [appState.autosaveTask, appState.statisticsTask, appState.workspaceReloadTask,
         appState.workspaceSearchTask, appState.completionWorkspaceTask].compactMap { $0 }
            + appState.externalReloadTasks.values.map(\.task)
            + appState.externalDiskInspectionTasks.values.map(\.task)
            + appState.sessionAutosaveTasks.values.map(\.task)
            + appState.sessionStatisticsTasks.values.map(\.task)
            + Array(appState.workspaceMutationTextRecoveryTasks.values)
    }

    func openFindBar(_ appState: AppState, query: String) {
        appState.editorFindHost.controller.debounceNanoseconds = 0
        appState.editorFindHost.commandContextOverride = true
        appState.showOrRefocusEditorFind()
        appState.handleEditorFindQueryTextChange(query)
    }

    func makeWorkspaceHost(
        appState: AppState,
        width: CGFloat = 1000,
        height: CGFloat = 680
    ) -> HostedWorkspace {
        #if DEBUG
            EditorPreviewScrollCoordinator.latestDebugInstance = nil
        #endif
        let root = WorkspaceWindow()
            .environmentObject(appState)
            .frame(width: width, height: height)
        let disposal = HostedRootDisappearance()
        let previewLifecycle = HostedPreviewLifecycle()
        let hostedRoot = root.onDisappear {
            disposal.markDisposed()
        }
        let hostingView = NSHostingView(rootView: AnyView(hostedRoot))
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
        #if DEBUG
            let mountedPreviewController = EditorPreviewScrollCoordinator
                .latestDebugInstance?
                .previewControllerForTesting
            XCTAssertNotNil(
                mountedPreviewController,
                "Hosted workspace did not mount its own preview controller"
            )
            previewLifecycle.capture(mountedPreviewController)
        #endif
        return HostedWorkspace(
            window: window,
            hostingView: hostingView,
            disposal: disposal,
            previewLifecycle: previewLifecycle
        )
    }

    func findQueryField(in window: NSWindow) -> NSTextField? {
        firstDescendant(of: NSTextField.self, in: window.contentView) {
            $0.accessibilityIdentifier() == EditorFindAccessibility.queryField
        }
    }

    func waitForFindQueryField(in window: NSWindow) async throws -> NSTextField {
        try await waitUntil("production find field mounts") {
            self.findQueryField(in: window) != nil
        }
        return try XCTUnwrap(findQueryField(in: window))
    }

    func waitForView<View: NSView>(
        _ type: View.Type,
        in window: NSWindow
    ) async throws -> View {
        try await waitUntil("\(View.self) mounts in production WorkspaceWindow") {
            self.firstDescendant(of: type, in: window.contentView) != nil
        }
        return try XCTUnwrap(firstDescendant(of: type, in: window.contentView))
    }

    func firstDescendant<View: NSView>(
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

    func waitUntil(
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

    func makeWorkspaceFixture(files: [String: String]) throws -> WorkspaceFixture {
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

    func makeLongPreviewDocument() -> LongPreviewDocument {
        let needle = "PLAINSONG_HOSTED_FIND_TARGET"
        var lines = ["# Hosted preview"]
        lines += (1 ... 180).flatMap { ["Paragraph before \($0)", ""] }
        let targetLine = lines.count + 1
        lines.append(needle)
        lines.append("")
        lines += (1 ... 180).flatMap { ["Paragraph after \($0)", ""] }
        return LongPreviewDocument(
            source: lines.joined(separator: "\n"),
            needle: needle,
            targetLine: targetLine
        )
    }

    func makeTwoMatchPreviewDocument() -> TwoMatchPreviewDocument {
        let needle = "PLAINSONG_HOSTED_OWNER_TARGET"
        var lines = ["# Hosted preview", needle, ""]
        lines += (1 ... 220).flatMap { ["Paragraph between \($0)", ""] }
        let secondLine = lines.count + 1
        lines.append(needle)
        let source = lines.joined(separator: "\n")
        let firstRange = (source as NSString).range(of: needle)
        let sourceLength = (source as NSString).length
        let remainder = NSRange(
            location: NSMaxRange(firstRange),
            length: sourceLength - NSMaxRange(firstRange)
        )
        let secondRange = (source as NSString).range(
            of: needle,
            options: [],
            range: remainder
        )
        return TwoMatchPreviewDocument(
            source: source,
            needle: needle,
            firstRange: firstRange,
            secondRange: secondRange,
            secondLine: secondLine
        )
    }
}

struct HostedWorkspace {
    let window: NSWindow
    let hostingView: NSHostingView<AnyView>
    let disposal: HostedRootDisappearance
    let previewLifecycle: HostedPreviewLifecycle
}

struct LongPreviewDocument {
    let source: String
    let needle: String
    let targetLine: Int
}

struct TwoMatchPreviewDocument {
    let source: String
    let needle: String
    let firstRange: NSRange
    let secondRange: NSRange
    let secondLine: Int
}

@MainActor
final class HostedRootDisappearance {
    let expectation = XCTestExpectation(description: "hosted root disappeared")
    private(set) var didDisappear = false

    func markDisposed() {
        guard !didDisappear else { return }
        didDisappear = true
        expectation.fulfill()
    }
}

@MainActor
final class HostedPreviewLifecycle {
    private weak var controller: PreviewController?
    private weak var webView: WKWebView?

    var controllerForShutdown: PreviewController? {
        controller
    }

    var isReleased: Bool {
        controller == nil && webView == nil
    }

    func capture(_ controller: PreviewController?) {
        self.controller = controller
        webView = controller?.webView
    }
}

@MainActor
struct WorkspaceFixture {
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

final class MemoryLastOpenedFileStore: LastOpenedFilePersisting {
    private var storedURL: URL?

    func save(_ url: URL) throws {
        storedURL = url
    }

    func restore() throws -> URL? {
        storedURL
    }
}

final class MemoryRecentItemStore: RecentItemPersisting {
    private var storedURLs: [URL] = []

    func save(_ url: URL) throws {
        storedURLs.removeAll { $0 == url }
        storedURLs.insert(url, at: 0)
    }

    func restore() throws -> [URL] {
        storedURLs
    }
}
