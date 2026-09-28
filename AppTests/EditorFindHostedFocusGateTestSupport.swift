import AppKit
@testable import EditorKit
import Foundation
@testable import Plainsong
@testable import PreviewKit
import SwiftUI
import XCTest

/// Hosted window whose **key status** the test designates.
///
/// The app-hosted XCTest process is never the active application: `NSApp.isActive` stays
/// `false` even after `NSApp.activate(ignoringOtherApps:)` and
/// `NSRunningApplication.current.activate(options:)`, so `makeKeyAndOrderFront` never produces
/// a real key window here. Only `isKeyWindow` is designated. Production code reads it live
/// (`EditorFindQueryField`'s retry loop, `AppState.isWorkspaceSearchFocusKeyWindow`), and the
/// AppKit key notifications `WindowKeyStateTracker` observes are posted on every change.
/// First responders, field editors, retry loops, and receipts are all real production state.
@MainActor
final class DesignatedKeyWindow: NSWindow {
    fileprivate(set) var isDesignatedKey = false

    override var isKeyWindow: Bool {
        isDesignatedKey
    }
}

/// Every hosted workspace a test mounts, torn down together so the shared `AppState` closes
/// its workspace exactly once, after every window has released its preview.
@MainActor
final class HostedWorkspaceGroup {
    fileprivate(set) var members: [(host: HostedWorkspace, window: DesignatedKeyWindow)] = []

    var windows: [DesignatedKeyWindow] {
        members.map(\.window)
    }
}

@MainActor
extension EditorFindHostedGateTests {
    func makeHostedWorkspaceGroup(fixture: WorkspaceFixture) -> HostedWorkspaceGroup {
        let group = HostedWorkspaceGroup()
        registerTeardown(group: group, fixture: fixture)
        return group
    }

    /// Mounts another production `WorkspaceWindow` on the shared `AppState`, not yet key.
    @discardableResult
    func mountDesignatedKeyWorkspace(
        in group: HostedWorkspaceGroup,
        appState: AppState,
        originX: CGFloat = 0
    ) -> DesignatedKeyWindow {
        let width: CGFloat = 1000
        let height: CGFloat = 680
        #if DEBUG
            EditorPreviewScrollCoordinator.latestDebugInstance = nil
        #endif
        let disposal = HostedRootDisappearance()
        let previewLifecycle = HostedPreviewLifecycle()
        let root = WorkspaceWindow()
            .environmentObject(appState)
            .frame(width: width, height: height)
            .onDisappear { disposal.markDisposed() }
        let hostingView = NSHostingView(rootView: AnyView(root))
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = DesignatedKeyWindow(
            contentRect: NSRect(x: originX, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        #if DEBUG
            let mounted = EditorPreviewScrollCoordinator.latestDebugInstance?.previewControllerForTesting
            XCTAssertNotNil(mounted, "Hosted workspace did not mount its own preview controller")
            previewLifecycle.capture(mounted)
        #endif
        let host = HostedWorkspace(
            window: window,
            hostingView: hostingView,
            disposal: disposal,
            previewLifecycle: previewLifecycle
        )
        group.members.append((host, window))
        return window
    }

    /// Makes `key` the only designated key window in `group` and posts the AppKit
    /// resign/become notifications a real key change would, then re-arms Search's key routing.
    func designateKeyWindow(_ key: DesignatedKeyWindow?, in group: HostedWorkspaceGroup, appState: AppState) {
        for window in group.windows where window !== key && window.isDesignatedKey {
            window.isDesignatedKey = false
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        }
        if let key, !key.isDesignatedKey {
            key.isDesignatedKey = true
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: key)
        }
        appState.refreshWorkspaceSearchFocusKeyRouting()
    }

    /// Whether `window`'s real first responder is its production find query field (or that
    /// field's field editor).
    func isFindFieldFirstResponder(in window: NSWindow) -> Bool {
        guard let field = findQueryField(in: window), let first = window.firstResponder else {
            return false
        }
        if first === field { return true }
        guard let editor = field.currentEditor() else { return false }
        return first === editor
    }

    /// The find field's live field-editor selection, when it is the first responder.
    func findFieldEditorSelection(in window: NSWindow) -> NSRange? {
        guard isFindFieldFirstResponder(in: window),
              let editor = findQueryField(in: window)?.currentEditor() as? NSTextView
        else {
            return nil
        }
        return editor.selectedRange()
    }

    func focusDiagnostics(_ windows: [NSWindow], _ appState: AppState) -> String {
        let responders = windows.map { window -> String in
            let first = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            return "#\(window.windowNumber) key=\(window.isKeyWindow) first=\(first) "
                + "find=\(isFindFieldFirstResponder(in: window)) "
                + "sel=\(String(describing: findFieldEditorSelection(in: window)))"
        }
        return "[\(responders.joined(separator: "; "))] snapshot=\(appState.editorFindHost.ui.focusSnapshot)"
    }

    /// `assertRemains` with every window's live first responder in the failure message.
    func assertFocusRemains(
        _ description: String,
        windows: [NSWindow],
        appState: AppState,
        file: StaticString = #filePath,
        line: UInt = #line,
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        try await assertRemains(
            description,
            file: file,
            line: line,
            diagnostics: { self.focusDiagnostics(windows, appState) },
            predicate: predicate
        )
    }

    /// A user click into the find field: AppKit focus plus a caret at the end of the query.
    func clickIntoFindField(in window: NSWindow) throws {
        let field = try XCTUnwrap(findQueryField(in: window))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: (field.stringValue as NSString).length, length: 0))
    }

    /// Forces SwiftUI to re-run every mounted find field's `updateNSView` without issuing a
    /// new focus or select-all request.
    func republishFindChrome(_ appState: AppState) {
        appState.setEditorFindUI(appState.editorFindHost.ui)
    }

    private func registerTeardown(group: HostedWorkspaceGroup, fixture: WorkspaceFixture) {
        addTeardownBlock { @MainActor in
            let appState = fixture.appState
            let tasks = self.activeTasks(in: appState)
            tasks.forEach { $0.cancel() }
            var previewControllers: [PreviewController] = []
            for member in group.members {
                member.window.isDesignatedKey = false
                let controller = member.host.previewLifecycle.controllerForShutdown
                XCTAssertNotNil(controller, "Hosted workspace did not expose its preview controller")
                controller?.shutdownForTesting()
                controller.map { previewControllers.append($0) }
                member.host.window.makeFirstResponder(nil)
                member.host.hostingView.rootView = AnyView(EmptyView())
                member.host.hostingView.layoutSubtreeIfNeeded()
            }
            for member in group.members {
                await self.fulfillment(of: [member.host.disposal.expectation], timeout: 2)
                XCTAssertTrue(member.host.disposal.didDisappear, "Hosted root did not report disappearance")
            }
            previewControllers.removeAll()
            for member in group.members {
                try await self.waitUntil("hosted PreviewController and WKWebView deallocate") {
                    member.host.previewLifecycle.isReleased
                }
                member.host.window.contentView = nil
                member.host.window.orderOut(nil)
                member.host.window.close()
            }
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
}
