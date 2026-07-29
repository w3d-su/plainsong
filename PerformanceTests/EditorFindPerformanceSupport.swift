import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import SwiftUI
import XCTest

/// Shared production-shaped fixture and timing vocabulary for the in-document find gates.
///
/// F2 measures query completion and live-query edit admission here. F8 may reuse the same
/// fixture/scenarios for find-highlight apply/clear once that production implementation lands;
/// this support deliberately does not manufacture a highlight surface in advance.
@MainActor
enum EditorFindPerformanceSupport {
    struct Scenario: Equatable {
        let label: String
        let pattern: String
        let expectedRetainedMatchCount: Int
        let expectedTruncation: Bool
        let completionBudgetMilliseconds: Double
    }

    @MainActor
    struct AppHarness {
        let appState: AppState
        let defaults: UserDefaults
        let defaultsSuiteName: String

        func cancelScheduledAppWork() {
            appState.autosaveTask?.cancel()
            appState.autosaveTask = nil
            appState.statisticsTask?.cancel()
            appState.statisticsTask = nil
            appState.completionWorkspaceTask?.cancel()
            appState.completionWorkspaceTask = nil
        }

        func cleanUp() {
            appState.editorFindHost.controller.cancelInFlightWork()
            appState.editorFindHost.controller.onSessionDidChange = nil
            cancelScheduledAppWork()
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
    }

    @MainActor
    struct HostedEditorHarness {
        let app: AppHarness
        let window: NSWindow
        let hostingView: NSView
        let textView: MarkdownSTTextView
        let coordinator: MarkdownTextViewCoordinator

        func cleanUp() {
            window.contentViewController = nil
            window.orderOut(nil)
            app.cleanUp()
        }
    }

    struct TimedSession: Equatable {
        let elapsedMilliseconds: Double
        let retainedMatchCount: Int
        let isTruncated: Bool
        let ranOffMain: Bool
    }

    static let fixtureByteCount = 1_048_962
    static let measuredSamplesPerScenario = 3
    static let measuredLiveEditCount = 5

    static let scenarios = [
        Scenario(
            label: "zero",
            pattern: "plainsong-f2-zero-hit",
            expectedRetainedMatchCount: 0,
            expectedTruncation: false,
            completionBudgetMilliseconds: 400
        ),
        Scenario(
            label: "sparse",
            pattern: "generated sections: 1274",
            expectedRetainedMatchCount: 1,
            expectedTruncation: false,
            completionBudgetMilliseconds: 400
        ),
        Scenario(
            label: "dense-truncated",
            // Reaches the 10,001 overflow match after scanning about 87% of this fixture.
            pattern: "section",
            expectedRetainedMatchCount: 10000,
            expectedTruncation: true,
            completionBudgetMilliseconds: 1100
        ),
    ]

    static func fixtureText(testBundle: Bundle) throws -> String {
        let url = try XCTUnwrap(
            testBundle.url(
                forResource: "large-1mb",
                withExtension: "md",
                subdirectory: "Fixtures"
            ),
            "missing bundled performance resource: Fixtures/large-1mb.md"
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(
            text.utf8.count,
            fixtureByteCount,
            "F2 fixture shape changed; remeasure before accepting a new byte count"
        )
        return text
    }

    static func makeAppHarness(fixtureText: String) throws -> AppHarness {
        let identifier = UUID().uuidString
        let defaultsSuiteName = "app.plainsong.editor-find-performance.\(identifier)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.set(60.0, forKey: "Plainsong.settings.autosaveIntervalSeconds")
        let session = DocumentSession(
            text: fixtureText,
            url: URL(fileURLWithPath: "/tmp/plainsong-editor-find-performance-\(identifier).md"),
            fileKind: .markdown
        )
        let appState = AppState(
            currentDocument: session,
            shouldRestoreLastOpenedFile: false,
            userDefaults: defaults
        )
        appState.editorFindHost.commandContextOverride = true
        appState.showOrRefocusEditorFind()
        return AppHarness(
            appState: appState,
            defaults: defaults,
            defaultsSuiteName: defaultsSuiteName
        )
    }

    static func makeHostedEditorHarness(
        fixtureText: String
    ) async throws -> HostedEditorHarness {
        let app = try makeAppHarness(fixtureText: fixtureText)
        let binding = app.appState.editorDocumentBinding(for: app.appState.currentDocument)
        let editor = MarkdownEditorView(
            text: binding.text,
            fileKind: .markdown,
            showsLineNumbers: false,
            documentIdentity: app.appState.activeEditorDocumentIdentity,
            documentBindingID: binding.id,
            onDocumentBindingLifecycle: binding.onLifecycle,
            documentSourceContract: binding.sourceContract
        )
        let frame = NSRect(x: 0, y: 0, width: 800, height: 240)
        let hostingController = NSHostingController(rootView: editor.frame(
            width: frame.width,
            height: frame.height
        ))
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
            return HostedEditorHarness(
                app: app,
                window: window,
                hostingView: hostingController.view,
                textView: textView,
                coordinator: coordinator
            )
        } catch {
            window.contentViewController = nil
            window.orderOut(nil)
            app.cleanUp()
            throw error
        }
    }

    static func settleScheduledSwiftUIUpdate(in harness: HostedEditorHarness) async {
        await Task.yield()
        harness.hostingView.layoutSubtreeIfNeeded()
    }

    static var isContinuousIntegration: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CI"] == "true" || environment["GITHUB_ACTIONS"] == "true"
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func formatSamples(_ values: [Double]) -> String {
        "[" + values.map { String(format: "%.3f", $0) }.joined(separator: ", ") + "]"
    }

    static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000
    }

    private static func waitForTextView(
        in rootView: NSView
    ) async throws -> MarkdownSTTextView {
        for _ in 0 ..< 200 {
            rootView.layoutSubtreeIfNeeded()
            if let textView = findTextView(in: rootView) {
                return textView
            }
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return try XCTUnwrap(findTextView(in: rootView))
    }

    private static func findTextView(in view: NSView) -> MarkdownSTTextView? {
        if let textView = view as? MarkdownSTTextView {
            return textView
        }
        if let scrollView = view as? NSScrollView,
           let textView = scrollView.documentView as? MarkdownSTTextView
        {
            return textView
        }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }
        return nil
    }
}
