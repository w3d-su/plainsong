import AppKit
@testable import EditorKit
import Foundation
@testable import Plainsong
@testable import PreviewKit
import SwiftUI
import WebKit
import XCTest

@MainActor
extension WorkspaceSearchHostedActivationTests {
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

    func makeWorkspaceHost(
        appState: AppState,
        width: CGFloat,
        height: CGFloat
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

    func makeSearchWorkspaceFixture(files: [String: String]) throws -> WorkspaceFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSearchHostedActivationTests")
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

        let suiteName = "WorkspaceSearchHostedActivationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let appState = AppState(
            lastOpenedFileStore: MemoryLastOpenedFileStore(),
            recentItemStore: MemoryRecentItemStore(),
            workspaceSearchDebounceNanoseconds: 0,
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

    func makeOffscreenOtherFileDocument() -> OffscreenSearchDocument {
        let needle = "PLAINSONG_WS_CLICK_TARGET"
        var lines = ["# Other file"]
        lines += (1 ... 220).flatMap { ["Padding before \($0)", ""] }
        lines.append(needle)
        lines.append("")
        lines += (1 ... 80).map { "Padding after \($0)" }
        let source = lines.joined(separator: "\n")
        return OffscreenSearchDocument(
            source: source,
            needle: needle,
            matchRange: (source as NSString).range(of: needle)
        )
    }

    func resultsPresentation(_ appState: AppState) -> WorkspaceSearchResultsPresentation {
        WorkspaceSearchResultsPresenter.make(
            searchState: appState.workspaceSearchState,
            queryText: appState.workspaceSearchUI.queryText,
            canUseWorkspaceSearch: true,
            isWorkspaceSearchReady: true
        )
    }

    func waitForResultsTable(in window: NSWindow) async throws -> NSTableView {
        try await waitUntil("search results table mounts with a hittable row") {
            guard let table = self.sidebarResultsTable(in: window) else { return false }
            return table.numberOfRows > 0 && table.rect(ofRow: table.numberOfRows - 1).height > 8
        }
        return try XCTUnwrap(sidebarResultsTable(in: window))
    }

    func sidebarResultsTable(in window: NSWindow) -> NSTableView? {
        var tables: [NSTableView] = []
        collect(NSTableView.self, from: window.contentView, into: &tables)
        return tables.first { table in
            table.convert(table.bounds, to: nil).minX < 280 && table.numberOfRows > 0
        } ?? tables.first
    }

    func collect<View: NSView>(_ type: View.Type, from root: NSView?, into matches: inout [View]) {
        guard let root else { return }
        if let match = root as? View {
            matches.append(match)
        }
        for child in root.subviews {
            collect(type, from: child, into: &matches)
        }
    }

    func sendClickOnLastRow(of tableView: NSTableView, to window: NSWindow) {
        let lastRow = tableView.numberOfRows - 1
        let rect = tableView.rect(ofRow: lastRow)
        let clickPoint = tableView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        XCTAssertLessThan(clickPoint.x, 280, "click must land in the sidebar, not the editor")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: clickPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else {
                XCTFail("Could not synthesize mouse event")
                return
            }
            window.sendEvent(event)
        }
    }

    func assertClickActivated(
        _ document: OffscreenSearchDocument,
        in window: NSWindow,
        appState: AppState
    ) async throws {
        try await waitUntil("click opens the other file and applies the exact UTF-16 match") {
            guard appState.currentDocument.fileURL?.lastPathComponent == "z-other.md" else {
                return false
            }
            let applied = EditorSelectionProbe.appliedEditorSelection(in: window)
            return applied?.isDocumentInstalled == true
                && applied?.range == document.matchRange
        }
        try await waitUntil("editor viewport contains the activated match") {
            guard let visible = EditorSelectionProbe.visibleTextRange(in: window) else {
                return false
            }
            return NSIntersectionRange(visible, document.matchRange).length == document.matchRange.length
        }
        let applied = try XCTUnwrap(EditorSelectionProbe.appliedEditorSelection(in: window))
        XCTAssertEqual(applied.range, document.matchRange)
        XCTAssertTrue(applied.isDocumentInstalled)
        XCTAssertEqual(
            applied.documentIdentity,
            appState.editorDocumentIdentity(for: appState.currentDocument)
        )
        #if DEBUG
            let expectedLabel =
                "Editor UTF-16 selection \(document.matchRange.location):\(document.matchRange.length)"
            try await waitUntil("debug selection observation matches the native range") {
                EditorNavigationDebugProbe.shared.observation?.selection == document.matchRange
                    || self.debugSelectedRangeLabel(in: window) == expectedLabel
            }
        #endif
    }

    func debugSelectedRangeLabel(in window: NSWindow) -> String? {
        var views: [NSView] = []
        collect(NSView.self, from: window.contentView, into: &views)
        return views.first {
            $0.accessibilityIdentifier() == "plainsong.debug.editor.selectedRange"
        }?.accessibilityLabel()
    }

    func waitUntil(
        _ description: String,
        timeout: TimeInterval = 8,
        predicate: @escaping @MainActor () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }
}

struct OffscreenSearchDocument {
    let source: String
    let needle: String
    let matchRange: NSRange
}
