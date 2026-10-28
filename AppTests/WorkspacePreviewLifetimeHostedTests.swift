import AppKit
@testable import Plainsong
@testable import PreviewKit
import SwiftUI
import XCTest

/// The workspace's `PreviewController` (and its `WKWebView`) must be owned only by the
/// `EditorWorkspace` view state. Closures that view hands to AppKit — the jump bar's menu
/// targets and the controller's own callbacks — once captured the whole view, so they
/// owned its `@StateObject` storage: the controller leaked when a workspace root went away
/// without a test-only shutdown, and a removed jump bar view that AppKit had not freed yet
/// kept it alive past the hosted teardown's 5 s wait on CI.
@MainActor
extension EditorFindHostedGateTests {
    /// Both shells: CI's macOS 15 runner only builds the fixed one (R17).
    private static let lifetimeCases: [(EditorLayoutMode, WorkspaceShell)] = [
        (.sourceOnly, .fixed), (.sourcePreview, .fixed), (.sourceOnly, .automatic), (.sourcePreview, .automatic),
    ]

    func testRemovedWorkspaceRootReleasesPreviewWithoutTestShutdown() async throws {
        for (layout, shell) in Self.lifetimeCases {
            let host = try await makeLifetimeHost(layout: layout, shell: shell)
            // Production never invalidates the workspace controller; only the view state
            // owns it, so removing the root alone must release it.
            host.hostingView.rootView = AnyView(EmptyView())
            host.hostingView.layoutSubtreeIfNeeded()
            try await waitUntil("\(layout) \(shell) preview releases without shutdownForTesting") {
                host.previewLifecycle.isReleased
            }
            XCTAssertTrue(host.previewLifecycle.isReleased, host.previewLifecycle.timeoutDescription)
        }
    }

    func testRemovedJumpBarViewsCannotKeepThePreviewAlive() async throws {
        for (layout, shell) in Self.lifetimeCases {
            let host = try await makeLifetimeHost(layout: layout, shell: shell)
            // Stand in for whatever retains a removed AppKit view after its root is gone
            // (an undrained autorelease pool, a window-held reference until close).
            let removedTargets = descendants(of: JumpBarMenuTarget.TargetView.self, in: host.window.contentView)
            XCTAssertFalse(removedTargets.isEmpty, "\(layout): the jump bar did not mount its menu targets")
            host.previewLifecycle.controllerForShutdown?.shutdownForTesting()
            host.hostingView.rootView = AnyView(EmptyView())
            host.hostingView.layoutSubtreeIfNeeded()
            XCTAssertTrue(removedTargets.allSatisfy { $0.window == nil })
            try await waitUntil("\(layout) \(shell) preview releases while removed jump bar views live") {
                host.previewLifecycle.isReleased
            }
            XCTAssertTrue(host.previewLifecycle.isReleased, host.previewLifecycle.timeoutDescription)
            withExtendedLifetime(removedTargets) {}
        }
    }

    /// A mounted workspace whose cleanup closes the window and workspace, and shuts the
    /// controller down only if a failed assertion left it alive. The controller is created on
    /// the first preview show, so the workspace mounts with the preview visible and then
    /// switches to `layout`: source-only covers a hidden pane that still owns its controller.
    private func makeLifetimeHost(layout: EditorLayoutMode, shell: WorkspaceShell) async throws -> HostedWorkspace {
        let fixture = try makeWorkspaceFixture(files: ["a.md": "# A", "b.md": "b"])
        let state = fixture.appState
        state.setLayoutMode(.sourcePreview)
        state.openExternalFile(fixture.root)
        try await waitUntil("\(layout) workspace opens") {
            state.shownSession.fileURL?.lastPathComponent == "a.md"
        }
        let host = makeWorkspaceHost(appState: state, shellOverride: shell)
        XCTAssertFalse(host.previewLifecycle.isReleased, "\(layout): no preview controller mounted")
        state.setLayoutMode(layout)
        host.hostingView.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            let tasks = self.activeTasks(in: state)
            tasks.forEach { $0.cancel() }
            host.previewLifecycle.controllerForShutdown?.shutdownForTesting()
            host.window.contentView = nil
            host.window.orderOut(nil)
            host.window.close()
            state.closeWorkspace()
            for task in tasks {
                await task.value
            }
            #if DEBUG
                EditorPreviewScrollCoordinator.latestDebugInstance = nil
            #endif
            fixture.cleanUp()
        }
        return host
    }

    private func descendants<View: NSView>(of type: View.Type, in root: NSView?) -> [View] {
        guard let root else { return [] }
        let match = (root as? View).map { [$0] } ?? []
        return match + root.subviews.flatMap { descendants(of: type, in: $0) }
    }
}
