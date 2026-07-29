@testable import EditorKit
import Foundation
@testable import Plainsong
import XCTest

@MainActor
extension EditorFindPerformanceTests {
    struct TimedWorkspaceEdit {
        let admissionMilliseconds: Double
        let stateUpdateReceiptMilliseconds: Double
    }

    struct WorkspaceEditSamples {
        var admission: [Double] = []
        var stateUpdateReceipt: [Double] = []
    }

    struct TimedWorkspaceInvalidationReceipt {
        let generation: UInt64
        let snapshot: EditorFindPerformanceSupport.WorkspaceUpdateSnapshot
        let endTime: UInt64
    }

    struct WorkspaceEditPreparation {
        let controller: EditorFindController
        let baselineCompletedCount: Int
        let completion: CompletionObservation
        let editorGeneration: UInt64
        let workspaceGeneration: UInt64
    }

    func runProductionWorkspaceEditProbe(
        in harness: EditorFindPerformanceSupport.HostedWorkspaceHarness
    ) async throws {
        let scenario = try XCTUnwrap(
            EditorFindPerformanceSupport.scenarios.first { $0.label == "dense-truncated" }
        )
        try await primeProductionWorkspaceFind(in: harness, scenario: scenario)
        let samples = try await measureProductionWorkspaceEdits(
            harness: harness,
            scenario: scenario
        )
        try reportProductionWorkspaceEditSamples(samples)
    }

    func primeProductionWorkspaceFind(
        in harness: EditorFindPerformanceSupport.HostedWorkspaceHarness,
        scenario: EditorFindPerformanceSupport.Scenario
    ) async throws {
        let appState = harness.app.appState
        XCTAssertTrue(harness.window.makeFirstResponder(harness.textView))
        try await Task.sleep(nanoseconds: 100_000_000)

        let initial = try await measureQueryCompletion(
            scenario,
            in: appState,
            label: "live-query prime"
        )
        assertSession(initial, matches: scenario, label: "live-query prime")
        _ = try await EditorFindPerformanceSupport.waitForWorkspaceUpdate(in: harness) {
            $0.documentRevision == appState.currentDocument.version
                && $0.isBarVisible
                && $0.queryText == scenario.pattern
                && $0.hasActiveQuery
                && $0.matchCounterText == "1 / 10000+"
                && $0.isTruncated
        }
        XCTAssertEqual(harness.queryField.stringValue, scenario.pattern)
        XCTAssertTrue(harness.queryField.window === harness.window)
        XCTAssertTrue(harness.window.makeFirstResponder(harness.textView))
    }

    func reportProductionWorkspaceEditSamples(
        _ samples: WorkspaceEditSamples
    ) throws {
        let admissionMedian = EditorFindPerformanceSupport.median(samples.admission)
        let receiptMedian = EditorFindPerformanceSupport.median(samples.stateUpdateReceipt)
        let receiptMaximum = try XCTUnwrap(samples.stateUpdateReceipt.max())
        print(String(
            format: "F2 PERF production WorkspaceWindow find-open edit 1MB "
                + "admission median %.3f ms samples %@; state-update receipt "
                + "median %.3f ms max %.3f ms samples %@",
            admissionMedian,
            EditorFindPerformanceSupport.formatSamples(samples.admission),
            receiptMedian,
            receiptMaximum,
            EditorFindPerformanceSupport.formatSamples(samples.stateUpdateReceipt)
        ))

        assertWallClockBudget(
            admissionMedian,
            lessThan: EditorFindPerformanceSupport.liveEditAdmissionBudgetMilliseconds,
            metric: "production find-open live-edit admission median"
        )

        // This transaction receipt does not close the separate keystroke-to-screen
        // criterion because it includes neither compositor presentation nor physical input.
        assertWallClockBudget(
            receiptMedian,
            lessThan: EditorFindPerformanceSupport.stateUpdateReceiptBudgetMilliseconds,
            metric: "production WorkspaceWindow find-open state-update receipt median"
        )
    }

    func measureProductionWorkspaceEdits(
        harness: EditorFindPerformanceSupport.HostedWorkspaceHarness,
        scenario: EditorFindPerformanceSupport.Scenario
    ) async throws -> WorkspaceEditSamples {
        harness.app.cancelScheduledAppWork()
        // Keep the deterministic edit in the mounted visible range. Moving the caret to the
        // 1 MiB tail would benchmark a cold full-document scroll/layout, not edit admission.
        harness.textView.textSelection = NSRange(location: 0, length: 0)
        let baselineVersion = harness.app.appState.currentDocument.version
        var samples = WorkspaceEditSamples()
        for iteration in 1 ... EditorFindPerformanceSupport.measuredLiveEditCount {
            let result = try await measureProductionWorkspaceEdit(
                iteration: iteration,
                baselineVersion: baselineVersion,
                harness: harness,
                scenario: scenario
            )
            samples.admission.append(result.admissionMilliseconds)
            samples.stateUpdateReceipt.append(result.stateUpdateReceiptMilliseconds)
            harness.app.cancelScheduledAppWork()
        }
        return samples
    }

    func measureProductionWorkspaceEdit(
        iteration: Int,
        baselineVersion: Int,
        harness: EditorFindPerformanceSupport.HostedWorkspaceHarness,
        scenario: EditorFindPerformanceSupport.Scenario
    ) async throws -> TimedWorkspaceEdit {
        let preparation = try prepareProductionWorkspaceEdit(
            iteration: iteration,
            harness: harness,
            scenario: scenario
        )
        defer {
            preparation.controller.onSessionDidChange = preparation.completion.previousObserver
        }

        let start = DispatchTime.now().uptimeNanoseconds
        preparation.completion.startTime = start
        harness.textView.insertText("x", replacementRange: .notFound)
        let admitted = DispatchTime.now().uptimeNanoseconds
        assertSynchronousEditAdmission(
            controller: preparation.controller,
            baselineCompletedCount: preparation.baselineCompletedCount,
            appState: harness.app.appState,
            expectedVersion: baselineVersion + iteration,
            expectedSourcePrefix: String(repeating: "x", count: iteration)
        )

        let invalidation = try await measureWorkspaceInvalidationReceipt(
            harness: harness,
            after: preparation.workspaceGeneration,
            expectedRevision: baselineVersion + iteration,
            scenario: scenario
        )
        try assertProductionWorkspaceUpdate(
            harness: harness,
            editorGenerationBefore: preparation.editorGeneration,
            iteration: iteration,
            snapshot: invalidation.snapshot,
            scenario: scenario
        )
        try await assertRecomputedWorkspaceUpdate(
            completion: preparation.completion,
            harness: harness,
            scenario: scenario,
            iteration: iteration,
            after: invalidation.generation
        )
        return TimedWorkspaceEdit(
            admissionMilliseconds: EditorFindPerformanceSupport.milliseconds(
                from: start,
                to: admitted
            ),
            stateUpdateReceiptMilliseconds: EditorFindPerformanceSupport.milliseconds(
                from: start,
                to: invalidation.endTime
            )
        )
    }

    func prepareProductionWorkspaceEdit(
        iteration: Int,
        harness: EditorFindPerformanceSupport.HostedWorkspaceHarness,
        scenario: EditorFindPerformanceSupport.Scenario
    ) throws -> WorkspaceEditPreparation {
        let controller = harness.app.appState.editorFindHost.controller
        let baselineCompletedCount = controller.completedMatchCount
        let completion = installCompletionObservation(
            on: harness.app.appState,
            after: baselineCompletedCount,
            pattern: scenario.pattern,
            label: "production-hosted live-query edit \(iteration)"
        )
        return try WorkspaceEditPreparation(
            controller: controller,
            baselineCompletedCount: baselineCompletedCount,
            completion: completion,
            editorGeneration: XCTUnwrap(
                harness.coordinator.preparedDocumentTransitionGeneration
            ),
            workspaceGeneration: harness.updateProbe.generation
        )
    }

    func measureWorkspaceInvalidationReceipt(
        harness: EditorFindPerformanceSupport.HostedWorkspaceHarness,
        after generation: UInt64,
        expectedRevision: Int,
        scenario: EditorFindPerformanceSupport.Scenario
    ) async throws -> TimedWorkspaceInvalidationReceipt {
        let receipt = try await EditorFindPerformanceSupport.waitForWorkspaceUpdate(
            in: harness,
            after: generation
        ) {
            $0.documentRevision == expectedRevision
                && $0.isBarVisible
                && $0.queryText == scenario.pattern
                && !$0.hasActiveQuery
                && $0.matchCounterText.isEmpty
                && !$0.isTruncated
        }
        harness.hostingView.layoutSubtreeIfNeeded()
        return TimedWorkspaceInvalidationReceipt(
            generation: receipt.generation,
            snapshot: receipt.snapshot,
            endTime: receipt.timestamp
        )
    }

    func assertRecomputedWorkspaceUpdate(
        completion: CompletionObservation,
        harness: EditorFindPerformanceSupport.HostedWorkspaceHarness,
        scenario: EditorFindPerformanceSupport.Scenario,
        iteration: Int,
        after generation: UInt64
    ) async throws {
        await fulfillment(of: [completion.expectation], timeout: 10)
        let resolved = try XCTUnwrap(
            completion.result(),
            "production-hosted live-query edit \(iteration) did not record the completed session"
        )
        assertSession(
            resolved,
            matches: scenario,
            label: "production-hosted live-query edit \(iteration)",
            sourceOffsetUTF16: iteration
        )
        _ = try await EditorFindPerformanceSupport.waitForWorkspaceUpdate(
            in: harness,
            after: generation
        ) {
            $0.documentRevision == harness.app.appState.currentDocument.version
                && $0.isBarVisible
                && $0.queryText == scenario.pattern
                && $0.hasActiveQuery
                && $0.matchCounterText == "1 / 10000+"
                && $0.isTruncated
        }
        XCTAssertEqual(harness.queryField.stringValue, scenario.pattern)
        XCTAssertTrue(harness.queryField.window === harness.window)
    }

    func assertSynchronousEditAdmission(
        controller: EditorFindController,
        baselineCompletedCount: Int,
        appState: AppState,
        expectedVersion: Int,
        expectedSourcePrefix: String
    ) {
        // Runs before any await: the old session is invalidated, and no new match
        // completion or navigation has been applied synchronously.
        XCTAssertEqual(controller.completedMatchCount, baselineCompletedCount)
        XCTAssertNil(controller.session)
        XCTAssertNil(controller.pendingNavigationCommand)
        XCTAssertEqual(appState.currentDocument.version, expectedVersion)
        XCTAssertTrue(appState.currentDocument.text.hasPrefix(expectedSourcePrefix))
    }

    func assertProductionWorkspaceUpdate(
        harness: EditorFindPerformanceSupport.HostedWorkspaceHarness,
        editorGenerationBefore: UInt64,
        iteration: Int,
        snapshot: EditorFindPerformanceSupport.WorkspaceUpdateSnapshot,
        scenario: EditorFindPerformanceSupport.Scenario
    ) throws {
        let generationAfter = try XCTUnwrap(
            harness.coordinator.preparedDocumentTransitionGeneration,
            "production editor lost its prepared transition after edit \(iteration)"
        )
        XCTAssertGreaterThan(
            generationAfter,
            editorGenerationBefore,
            "production editor representable update did not run for edit \(iteration)"
        )
        XCTAssertEqual(harness.textView.text, harness.app.appState.currentDocument.text)
        XCTAssertTrue(snapshot.isBarVisible)
        XCTAssertEqual(snapshot.queryText, scenario.pattern)
        XCTAssertFalse(snapshot.hasActiveQuery)
        XCTAssertEqual(snapshot.matchCounterText, "")
        XCTAssertFalse(snapshot.isTruncated)
        XCTAssertEqual(harness.queryField.stringValue, scenario.pattern)
        XCTAssertTrue(harness.queryField.window === harness.window)
    }
}
