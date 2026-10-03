import AppKit
@testable import EditorKit
import MarkdownCore
@testable import Plainsong
import SwiftUI
import XCTest

@MainActor
final class AppBackedEditorPerformanceTests: XCTestCase {
    func testAuthorizedDocumentPublicationInvariantsStayWithinFrameBudgetForOneMiBSource() throws {
        let persistedSource = try Self.fixtureText("Fixtures/large-1mb.md") + "\nA"
        XCTAssertGreaterThanOrEqual(persistedSource.utf8.count, 1_048_576)

        // Build independent buffers before timing so each sample exercises literal
        // source comparison without charging fixture allocation to the hot path.
        let exactNoOpSource = String(decoding: Array(persistedSource.utf8), as: UTF8.self)
        let editedSource = String(persistedSource.dropLast()) + "B"
        let restoredSource = String(decoding: Array(persistedSource.utf8), as: UTF8.self)
        let session = DocumentSession(text: persistedSource, fileKind: .markdown)

        let exactNoOpLatency = measureDocumentSessionPublication {
            session.replaceTextFromAuthorizedEditor(exactNoOpSource, refreshStatistics: false)
        }
        XCTAssertEqual(session.version, 0)
        XCTAssertFalse(session.isDirty)

        let sameLengthEditLatency = measureDocumentSessionPublication {
            session.replaceTextFromAuthorizedEditor(editedSource, refreshStatistics: false)
        }
        XCTAssertEqual(session.version, 1)
        XCTAssertTrue(session.isDirty)

        let persistedBaselineLatency = measureDocumentSessionPublication {
            session.replaceTextFromAuthorizedEditor(restoredSource, refreshStatistics: false)
        }
        XCTAssertEqual(session.version, 2)
        XCTAssertFalse(session.isDirty)

        print(String(
            format: "WS3B PERF authorized publication 1 MiB no-op %.3f ms, tail edit %.3f ms, baseline %.3f ms",
            exactNoOpLatency,
            sameLengthEditLatency,
            persistedBaselineLatency
        ))
        assertFrameBudget(exactNoOpLatency, label: "authorized exact no-op")
        assertFrameBudget(sameLengthEditLatency, label: "authorized same-length tail edit")
        assertFrameBudget(persistedBaselineLatency, label: "authorized persisted-baseline restore")
    }

    func testHostedPublicEditorCurrentRevisionInputAndMarkedTextStayWithinFrameBudget() async throws {
        let source = try "AoldB" + (Self.fixtureText("Fixtures/large-1mb.md"))
        XCTAssertGreaterThanOrEqual(source.utf8.count, 1_048_576)
        let appFixture = try await makeAppFixture(
            source: source,
            directoryPrefix: "AppBackedEditorPerformanceTests",
            fileName: "large.md"
        )
        defer { tearDownAppFixture(appFixture) }
        let fixture = appFixture.editor

        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.textSelection = NSRange(location: 0, length: 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        await settleScheduledSwiftUIUpdate(in: fixture)

        try await assertAppBackedStaleIMEBoundaryReconciliation(
            in: appFixture,
            caretLocation: 1,
            expectedPrefix: "A\u{81FA}e\u{0301}\u{1F9EA}B"
        )
        cancelScheduledAppWork(in: appFixture.appState)
        try await Task.sleep(nanoseconds: 100_000_000)
        await settleScheduledSwiftUIUpdate(in: fixture)
        appFixture.appState.editorDocumentSourceFullComparisonCounts.removeAll()
        assertNoFullSourceComparisons(in: appFixture.appState)
        fixture.textView.textSelection = NSRange(location: 0, length: 0)

        let ordinaryLatency = await measureHostedUpdate(in: fixture) {
            fixture.textView.insertText("a", replacementRange: .notFound)
        }
        let pairLatency = await measureHostedUpdate(in: fixture) {
            fixture.textView.insertText("(", replacementRange: .notFound)
        }
        let markedTextLatencies = await measureMarkedTextUpdates(in: fixture)

        // Let the public view's debounced background highlight lifecycle drain too.
        // Its MainActor request preparation is source-size-independent; this delayed
        // cycle must also avoid the instrumented App/native whole-source comparisons.
        try await Task.sleep(nanoseconds: 100_000_000)
        await settleScheduledSwiftUIUpdate(in: fixture)

        XCTAssertTrue(appFixture.session.text.hasPrefix("a()\u{8A3B}e\u{0301}"))
        XCTAssertEqual(fixture.textView.text, appFixture.session.text)
        assertNoFullSourceComparisons(in: appFixture.appState)
        print(String(
            format: "WS3B PERF hosted public 1 MiB ordinary %.3f ms, pair %.3f ms, marked max %.3f ms",
            ordinaryLatency,
            pairLatency,
            markedTextLatencies.max() ?? 0
        ))
        assertFrameBudget(ordinaryLatency, label: "ordinary insertion")
        assertFrameBudget(pairLatency, label: "re-entrant pair insertion")
        for (index, latency) in markedTextLatencies.enumerated() {
            assertFrameBudget(latency, label: "marked-text update \(index + 1)")
        }
    }

    func testHostedAppStateStaleIMEReplacementBoundariesPreserveExactUTF16() async throws {
        let scenarios: [(caretLocation: Int, expectedPrefix: String)] = [
            (1, "A\u{81FA}e\u{0301}\u{1F9EA}B"),
            (4, "A\u{1F9EA}\u{81FA}e\u{0301}B"),
        ]

        for scenario in scenarios {
            try await assertHostedAppStateStaleIMEBoundary(
                caretLocation: scenario.caretLocation,
                expectedPrefix: scenario.expectedPrefix
            )
        }
    }

    func testHostedSelectionOnlyClosingSkipLeavesAppAndDiskStateUnchanged() async throws {
        let source = "()"
        let appFixture = try await makeAppFixture(
            source: source,
            directoryPrefix: "AppBackedEditorSelectionTests",
            fileName: "selection.md"
        )
        defer { tearDownAppFixture(appFixture) }
        let fixture = appFixture.editor
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        fixture.textView.textSelection = NSRange(location: 1, length: 0)
        await settleScheduledSwiftUIUpdate(in: fixture)
        appFixture.appState.editorDocumentSourceFullComparisonCounts.removeAll()

        fixture.textView.insertText(")", replacementRange: .notFound)
        await settleScheduledSwiftUIUpdate(in: fixture)

        XCTAssertEqual(fixture.textView.selectedRange(), NSRange(location: 2, length: 0))
        XCTAssertEqual(fixture.textView.text, source)
        XCTAssertEqual(appFixture.session.text, source)
        XCTAssertEqual(appFixture.session.version, 0)
        XCTAssertFalse(appFixture.session.isDirty)
        XCTAssertNil(appFixture.appState.autosaveTask)
        XCTAssertEqual(try String(contentsOf: appFixture.documentURL, encoding: .utf8), source)
        assertNoFullSourceComparisons(in: appFixture.appState)
    }
}
