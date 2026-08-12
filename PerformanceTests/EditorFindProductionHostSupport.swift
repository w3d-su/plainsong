import AppKit
@testable import EditorKit
import Foundation
@testable import Plainsong
import SwiftUI
import XCTest

@MainActor
extension EditorFindPerformanceSupport {
    struct WorkspaceUpdateSnapshot: Hashable {
        let documentRevision: Int
        let isBarVisible: Bool
        let queryText: String
        let hasActiveQuery: Bool
        let matchCounterText: String
        let isTruncated: Bool
    }

    struct WorkspaceUpdateReceipt {
        let generation: UInt64
        let snapshot: WorkspaceUpdateSnapshot
        /// Entry time for the root's test-only `NSViewRepresentable.updateNSView`.
        /// This is not child layout or compositor presentation.
        let timestamp: UInt64
    }

    /// Plain test storage: recording during `updateNSView` does not publish SwiftUI state.
    /// History prevents a later unrelated update from overwriting an awaited receipt.
    final class WorkspaceUpdateProbe {
        private(set) var generation: UInt64 = 0
        private(set) var receipts: [WorkspaceUpdateReceipt] = []

        func record(_ snapshot: WorkspaceUpdateSnapshot, timestamp: UInt64) {
            generation &+= 1
            receipts.append(WorkspaceUpdateReceipt(
                generation: generation,
                snapshot: snapshot,
                timestamp: timestamp
            ))
            if receipts.count > 256 {
                receipts.removeFirst(receipts.count - 256)
            }
        }

        func firstReceipt(
            after generation: UInt64,
            matching predicate: (WorkspaceUpdateSnapshot) -> Bool
        ) -> WorkspaceUpdateReceipt? {
            receipts.first {
                $0.generation > generation && predicate($0.snapshot)
            }
        }
    }

    @MainActor
    struct HostedWorkspaceHarness {
        let app: AppHarness
        let window: NSWindow
        let hostingView: NSView
        let textView: MarkdownSTTextView
        let coordinator: MarkdownTextViewCoordinator
        let queryField: NSTextField
        let updateProbe: WorkspaceUpdateProbe

        func cleanUp() async {
            app.appState.editorFindHost.controller.cancelInFlightWork()
            app.appState.editorFindHost.controller.onSessionDidChange = nil
            app.cancelScheduledAppWork()
            if textView.hasMarkedText() {
                textView.unmarkText()
            }
            window.makeFirstResponder(nil)
            await Task.yield()
            hostingView.layoutSubtreeIfNeeded()
            window.contentViewController = nil
            window.orderOut(nil)
            await Task.yield()
            app.cleanUp()
        }
    }

    static func makeHostedWorkspaceHarness(
        fixtureText: String
    ) async throws -> HostedWorkspaceHarness {
        let app = try makeAppHarness(fixtureText: fixtureText, opensFind: false)
        let updateProbe = WorkspaceUpdateProbe()
        let frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
        let root = EditorFindPerformanceWorkspaceRoot(
            appState: app.appState,
            updateProbe: updateProbe
        )
        .frame(width: frame.width, height: frame.height)
        let hostingController = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.makeKeyAndOrderFront(nil)

        do {
            let textView = try await waitForTextView(in: hostingController.view)
            let coordinator = try XCTUnwrap(
                textView.textDelegate as? MarkdownTextViewCoordinator
            )
            XCTAssertTrue(window.makeFirstResponder(textView))

            app.appState.showOrRefocusEditorFind()
            let queryField = try await waitForQueryField(in: hostingController.view)
            app.appState.supersedePendingEditorFindFocus()
            XCTAssertTrue(window.makeFirstResponder(textView))

            let harness = HostedWorkspaceHarness(
                app: app,
                window: window,
                hostingView: hostingController.view,
                textView: textView,
                coordinator: coordinator,
                queryField: queryField,
                updateProbe: updateProbe
            )
            _ = try await waitForWorkspaceUpdate(in: harness) {
                $0.isBarVisible && $0.documentRevision == app.appState.currentDocument.version
            }
            return harness
        } catch {
            window.makeFirstResponder(nil)
            window.contentViewController = nil
            window.orderOut(nil)
            app.cleanUp()
            throw error
        }
    }

    static func waitForWorkspaceUpdate(
        in harness: HostedWorkspaceHarness,
        after generation: UInt64 = 0,
        matching predicate: (WorkspaceUpdateSnapshot) -> Bool
    ) async throws -> WorkspaceUpdateReceipt {
        for attempt in 0 ..< 200 {
            harness.hostingView.layoutSubtreeIfNeeded()
            if let receipt = harness.updateProbe.firstReceipt(
                after: generation,
                matching: predicate
            ) {
                return receipt
            }
            await Task.yield()
            if attempt >= 20 {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        return try XCTUnwrap(
            harness.updateProbe.firstReceipt(after: generation, matching: predicate),
            "production WorkspaceWindow did not publish the expected find/editor update"
        )
    }

    private static func waitForQueryField(in rootView: NSView) async throws -> NSTextField {
        for _ in 0 ..< 200 {
            rootView.layoutSubtreeIfNeeded()
            if let field = findQueryField(in: rootView) {
                return field
            }
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return try XCTUnwrap(
            findQueryField(in: rootView),
            "WorkspaceWindow did not mount the shipped EditorFindBar query field"
        )
    }

    private static func findQueryField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField,
           field.accessibilityIdentifier() == EditorFindAccessibility.queryField
        {
            return field
        }
        for subview in view.subviews {
            if let field = findQueryField(in: subview) {
                return field
            }
        }
        return nil
    }
}

@MainActor
private struct EditorFindPerformanceWorkspaceRoot: View {
    @ObservedObject var appState: AppState
    let updateProbe: EditorFindPerformanceSupport.WorkspaceUpdateProbe

    var body: some View {
        let ui = appState.editorFindHost.ui
        let snapshot = EditorFindPerformanceSupport.WorkspaceUpdateSnapshot(
            documentRevision: appState.currentDocument.version,
            isBarVisible: ui.isBarVisible,
            queryText: ui.queryText,
            hasActiveQuery: ui.hasActiveQuery,
            matchCounterText: ui.matchCounterText,
            isTruncated: ui.isTruncated
        )

        WorkspaceWindow()
            .environmentObject(appState)
            .background(EditorFindPerformanceUpdateReceipt(
                snapshot: snapshot,
                updateProbe: updateProbe
            ))
    }
}

@MainActor
private struct EditorFindPerformanceUpdateReceipt: NSViewRepresentable {
    let snapshot: EditorFindPerformanceSupport.WorkspaceUpdateSnapshot
    let updateProbe: EditorFindPerformanceSupport.WorkspaceUpdateProbe

    func makeNSView(context _: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_: NSView, context _: Context) {
        updateProbe.record(
            snapshot,
            timestamp: DispatchTime.now().uptimeNanoseconds
        )
    }
}
