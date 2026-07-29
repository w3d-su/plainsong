import AppKit
@testable import EditorKit
import Foundation
import MarkdownCore
@testable import Plainsong
import SwiftUI
import WorkspaceKit
import XCTest

/// Shared production-shaped fixture and timing vocabulary for the in-document find gates.
///
/// F2 measures query completion and live-query edit admission here. F8 may reuse the same
/// fixture/scenarios for find-highlight apply/clear once that production implementation lands;
/// this support deliberately does not manufacture a highlight surface in advance.
@MainActor
enum EditorFindPerformanceSupport {
    struct ExpectedMatchEndpoint: Equatable {
        let range: NSRange
        let line: Int

        func shifted(byUTF16 offset: Int) -> ExpectedMatchEndpoint {
            ExpectedMatchEndpoint(
                range: NSRange(location: range.location + offset, length: range.length),
                line: line
            )
        }
    }

    struct Scenario: Equatable {
        let label: String
        let pattern: String
        let expectedRetainedMatchCount: Int
        let expectedTruncation: Bool
        let expectedFirstMatch: ExpectedMatchEndpoint?
        let expectedLastRetainedMatch: ExpectedMatchEndpoint?
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

    struct TimedSession: Equatable {
        let elapsedMilliseconds: Double
        let retainedMatchCount: Int
        let isTruncated: Bool
        let ranOffMain: Bool
        let firstMatch: ExpectedMatchEndpoint?
        let lastRetainedMatch: ExpectedMatchEndpoint?
    }

    static let fixtureByteCount = 1_048_962
    static let fixtureSHA256 = "d174f48ea6175db568abe44e5b71e82ee92f1cf9c0ed081d8f8308cc1961d247"
    static let measuredSamplesPerScenario = 3
    static let measuredLiveEditCount = 5
    static let liveEditAdmissionBudgetMilliseconds = 5.0
    static let stateUpdateReceiptBudgetMilliseconds = 15.0

    static let scenarios = [
        Scenario(
            label: "zero",
            pattern: "plainsong-f2-zero-hit",
            expectedRetainedMatchCount: 0,
            expectedTruncation: false,
            expectedFirstMatch: nil,
            expectedLastRetainedMatch: nil,
            completionBudgetMilliseconds: 400
        ),
        Scenario(
            label: "sparse",
            pattern: "generated sections: 1274",
            expectedRetainedMatchCount: 1,
            expectedTruncation: false,
            expectedFirstMatch: ExpectedMatchEndpoint(
                range: NSRange(location: 1_048_904, length: 24),
                line: 33140
            ),
            expectedLastRetainedMatch: ExpectedMatchEndpoint(
                range: NSRange(location: 1_048_904, length: 24),
                line: 33140
            ),
            completionBudgetMilliseconds: 400
        ),
        Scenario(
            label: "dense-truncated",
            // Reaches the 10,001 overflow match after scanning about 87% of this fixture.
            pattern: "section",
            expectedRetainedMatchCount: 10000,
            expectedTruncation: true,
            expectedFirstMatch: ExpectedMatchEndpoint(
                range: NSRange(location: 399, length: 7),
                line: 15
            ),
            expectedLastRetainedMatch: ExpectedMatchEndpoint(
                range: NSRange(location: 914_752, length: 7),
                line: 28901
            ),
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
        let fingerprint = WorkspaceSearchContentFingerprint(text: text)
        return try XCTUnwrap(
            fingerprint.utf8ByteCount == fixtureByteCount
                && fingerprint.sha256Digest == fixtureSHA256
                ? text
                : nil,
            """
            F2 fixture identity changed; remeasure and update byte count, SHA-256, \
            and deterministic match-position pins together. Expected \
            \(fixtureByteCount) bytes / \(fixtureSHA256), got \
            \(fingerprint.utf8ByteCount) / \(fingerprint.sha256Digest).
            """
        )
    }

    static func makeAppHarness(
        fixtureText: String,
        opensFind: Bool = true
    ) throws -> AppHarness {
        let identifier = UUID().uuidString
        let defaultsSuiteName = "app.plainsong.editor-find-performance.\(identifier)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.set(60.0, forKey: "Plainsong.settings.autosaveIntervalSeconds")
        defaults.set(EditorLayoutMode.sourceOnly.rawValue, forKey: AppState.layoutModeDefaultsKey)
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
        if opensFind {
            appState.showOrRefocusEditorFind()
        }
        return AppHarness(
            appState: appState,
            defaults: defaults,
            defaultsSuiteName: defaultsSuiteName
        )
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

    static func waitForTextView(
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

    static func findTextView(in view: NSView) -> MarkdownSTTextView? {
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
