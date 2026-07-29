@testable import EditorKit
import Foundation
@testable import Plainsong
import XCTest

/// F2 production-shaped performance probes over the committed 1 MiB editor fixture.
///
/// Query timing retains the production 150 ms debounce and drives App's real query-change
/// entry point through `EditorFindController` to the applied App presentation. Typing timing
/// drives a hosted `MarkdownEditorView` input through the production writer and App binding,
/// then awaits the real off-main recompute outside the wall-clock measurement.
@MainActor
final class EditorFindPerformanceTests: XCTestCase {
    func testLargeFixtureFindQueryCompletionForZeroSparseAndDenseCases() async throws {
        let fixture = try EditorFindPerformanceSupport.fixtureText(
            testBundle: Bundle(for: Self.self)
        )
        let harness = try EditorFindPerformanceSupport.makeAppHarness(fixtureText: fixture)
        defer { harness.cleanUp() }
        let appState = harness.appState
        XCTAssertEqual(
            appState.editorFindHost.controller.debounceNanoseconds,
            150_000_000,
            "F2 must retain the production query debounce"
        )

        for scenario in EditorFindPerformanceSupport.scenarios {
            _ = try await measureQueryCompletion(
                scenario,
                in: appState,
                label: "\(scenario.label) warm-up"
            )

            var samples: [Double] = []
            for attempt in 1 ... EditorFindPerformanceSupport.measuredSamplesPerScenario {
                let result = try await measureQueryCompletion(
                    scenario,
                    in: appState,
                    label: "\(scenario.label) sample \(attempt)"
                )
                assertSession(result, matches: scenario, label: "sample \(attempt)")
                samples.append(result.elapsedMilliseconds)
            }

            let median = EditorFindPerformanceSupport.median(samples)
            print(String(
                format: "F2 PERF find query %@ 1MB median %.3f ms samples %@ (%d retained, truncated=%@)",
                scenario.label,
                median,
                EditorFindPerformanceSupport.formatSamples(samples),
                scenario.expectedRetainedMatchCount,
                scenario.expectedTruncation.description
            ))
            assertWallClockBudget(
                median,
                lessThan: scenario.completionBudgetMilliseconds,
                metric: "find query \(scenario.label) completion median"
            )
        }
    }

    func testHostedLargeFixtureLiveQueryTypingStaysWithinFrameBudgetAndSearchesOffMain()
        async throws
    {
        let fixture = try EditorFindPerformanceSupport.fixtureText(
            testBundle: Bundle(for: Self.self)
        )
        let harness = try await EditorFindPerformanceSupport.makeHostedEditorHarness(
            fixtureText: fixture
        )
        defer { harness.cleanUp() }
        let appState = harness.app.appState
        let scenario = try XCTUnwrap(
            EditorFindPerformanceSupport.scenarios.first { $0.label == "dense-truncated" }
        )

        XCTAssertTrue(harness.window.makeFirstResponder(harness.textView))
        try await Task.sleep(nanoseconds: 100_000_000)
        await EditorFindPerformanceSupport.settleScheduledSwiftUIUpdate(in: harness)

        let initial = try await measureQueryCompletion(
            scenario,
            in: appState,
            label: "live-query prime"
        )
        assertSession(initial, matches: scenario, label: "live-query prime")

        let samples = try await measureHostedLiveQueryTyping(
            harness: harness,
            scenario: scenario
        )
        let admissionMedian = EditorFindPerformanceSupport.median(samples.admission)
        let updateMedian = EditorFindPerformanceSupport.median(samples.presentedUpdate)
        let updateMaximum = try XCTUnwrap(samples.presentedUpdate.max())
        print(String(
            format: "F2 PERF hosted live-query typing 1MB admission median %.3f ms samples %@; "
                + "presented update median %.3f ms max %.3f ms samples %@",
            admissionMedian,
            EditorFindPerformanceSupport.formatSamples(samples.admission),
            updateMedian,
            updateMaximum,
            EditorFindPerformanceSupport.formatSamples(samples.presentedUpdate)
        ))

        // This is the existing product frame budget (agent.md §12), not a new measured budget.
        assertWallClockBudget(
            updateMaximum,
            lessThan: 16.0,
            metric: "hosted live-query typing presented-update max"
        )
    }
}

private extension EditorFindPerformanceTests {
    struct TimedHostedEdit {
        let admissionMilliseconds: Double
        let presentedUpdateMilliseconds: Double
    }

    struct HostedTypingSamples {
        var admission: [Double] = []
        var presentedUpdate: [Double] = []
    }

    final class CompletionObservation {
        let expectation: XCTestExpectation
        let previousObserver: (() -> Void)?
        var startTime: UInt64?
        private var timedSession: EditorFindPerformanceSupport.TimedSession?

        init(expectation: XCTestExpectation, previousObserver: (() -> Void)?) {
            self.expectation = expectation
            self.previousObserver = previousObserver
        }

        func record(_ result: EditorFindPerformanceSupport.TimedSession) {
            guard timedSession == nil else { return }
            timedSession = result
            expectation.fulfill()
        }

        func result() -> EditorFindPerformanceSupport.TimedSession? {
            timedSession
        }
    }

    func measureHostedLiveQueryEdit(
        iteration: Int,
        baselineVersion: Int,
        expectedSourcePrefix: String,
        harness: EditorFindPerformanceSupport.HostedEditorHarness,
        scenario: EditorFindPerformanceSupport.Scenario
    ) async throws -> TimedHostedEdit {
        let appState = harness.app.appState
        let controller = appState.editorFindHost.controller
        let baselineCompletedCount = controller.completedMatchCount
        let completion = installCompletionObservation(
            on: appState,
            after: baselineCompletedCount,
            pattern: scenario.pattern,
            label: "hosted live-query edit \(iteration)"
        )
        defer { controller.onSessionDidChange = completion.previousObserver }
        let generationBefore = try XCTUnwrap(
            harness.coordinator.preparedDocumentTransitionGeneration,
            "hosted editor did not expose a prepared transition before edit \(iteration)"
        )

        let start = DispatchTime.now().uptimeNanoseconds
        completion.startTime = start
        harness.textView.insertText("x", replacementRange: .notFound)
        let admitted = DispatchTime.now().uptimeNanoseconds

        assertSynchronousEditAdmission(
            controller: controller,
            baselineCompletedCount: baselineCompletedCount,
            appState: appState,
            expectedVersion: baselineVersion + iteration,
            expectedSourcePrefix: expectedSourcePrefix
        )

        await EditorFindPerformanceSupport.settleScheduledSwiftUIUpdate(in: harness)
        let presented = DispatchTime.now().uptimeNanoseconds
        try assertPresentedEditorUpdate(
            harness: harness,
            generationBefore: generationBefore,
            iteration: iteration
        )

        await fulfillment(of: [completion.expectation], timeout: 10)
        let resolved = try XCTUnwrap(
            completion.result(),
            "hosted live-query edit \(iteration) did not record the completed session"
        )
        assertSession(resolved, matches: scenario, label: "hosted live-query edit \(iteration)")
        return TimedHostedEdit(
            admissionMilliseconds: EditorFindPerformanceSupport.milliseconds(
                from: start,
                to: admitted
            ),
            presentedUpdateMilliseconds: EditorFindPerformanceSupport.milliseconds(
                from: start,
                to: presented
            )
        )
    }

    func measureHostedLiveQueryTyping(
        harness: EditorFindPerformanceSupport.HostedEditorHarness,
        scenario: EditorFindPerformanceSupport.Scenario
    ) async throws -> HostedTypingSamples {
        harness.app.cancelScheduledAppWork()
        // Keep the deterministic edit in the mounted visible range. Moving the caret to the
        // 1 MiB tail would benchmark a cold full-document scroll/layout, not typing admission.
        harness.textView.textSelection = NSRange(location: 0, length: 0)
        let baselineVersion = harness.app.appState.currentDocument.version
        var samples = HostedTypingSamples()
        for iteration in 1 ... EditorFindPerformanceSupport.measuredLiveEditCount {
            let result = try await measureHostedLiveQueryEdit(
                iteration: iteration,
                baselineVersion: baselineVersion,
                expectedSourcePrefix: String(repeating: "x", count: iteration),
                harness: harness,
                scenario: scenario
            )
            samples.admission.append(result.admissionMilliseconds)
            samples.presentedUpdate.append(result.presentedUpdateMilliseconds)
            harness.app.cancelScheduledAppWork()
        }
        return samples
    }

    func assertSynchronousEditAdmission(
        controller: EditorFindController,
        baselineCompletedCount: Int,
        appState: AppState,
        expectedVersion: Int,
        expectedSourcePrefix: String
    ) {
        // Runs before any await: the old session is invalidated without a synchronous scan.
        XCTAssertEqual(controller.completedMatchCount, baselineCompletedCount)
        XCTAssertNil(controller.session)
        XCTAssertNil(controller.pendingNavigationCommand)
        XCTAssertEqual(appState.currentDocument.version, expectedVersion)
        XCTAssertTrue(appState.currentDocument.text.hasPrefix(expectedSourcePrefix))
    }

    func assertPresentedEditorUpdate(
        harness: EditorFindPerformanceSupport.HostedEditorHarness,
        generationBefore: UInt64,
        iteration: Int
    ) throws {
        let generationAfter = try XCTUnwrap(
            harness.coordinator.preparedDocumentTransitionGeneration,
            "hosted editor lost its prepared transition after edit \(iteration)"
        )
        XCTAssertGreaterThan(
            generationAfter,
            generationBefore,
            "hosted SwiftUI representable update did not run for edit \(iteration)"
        )
        XCTAssertEqual(harness.textView.text, harness.app.appState.currentDocument.text)
    }
}

private extension EditorFindPerformanceTests {
    func measureQueryCompletion(
        _ scenario: EditorFindPerformanceSupport.Scenario,
        in appState: AppState,
        label: String
    ) async throws -> EditorFindPerformanceSupport.TimedSession {
        let controller = appState.editorFindHost.controller
        let baselineCompletedCount = controller.completedMatchCount
        let observation = installCompletionObservation(
            on: appState,
            after: baselineCompletedCount,
            pattern: scenario.pattern,
            label: label
        )
        defer { controller.onSessionDidChange = observation.previousObserver }

        let start = DispatchTime.now().uptimeNanoseconds
        observation.startTime = start
        appState.handleEditorFindQueryTextChange(scenario.pattern)
        await fulfillment(of: [observation.expectation], timeout: 10)

        let result = try XCTUnwrap(observation.result(), "\(label) did not record a session")
        assertSession(result, matches: scenario, label: label)
        return result
    }

    func installCompletionObservation(
        on appState: AppState,
        after baselineCompletedCount: Int,
        pattern: String,
        label: String
    ) -> CompletionObservation {
        let controller = appState.editorFindHost.controller
        let previous = controller.onSessionDidChange
        let observation = CompletionObservation(
            expectation: expectation(description: "F2 completion: \(label)"),
            previousObserver: previous
        )
        controller.onSessionDidChange = { [weak controller, weak observation] in
            previous?()
            guard let controller,
                  let observation,
                  controller.completedMatchCount > baselineCompletedCount,
                  controller.session?.query.pattern == pattern,
                  let start = observation.startTime
            else {
                return
            }
            let end = DispatchTime.now().uptimeNanoseconds
            let session = controller.session
            observation.record(EditorFindPerformanceSupport.TimedSession(
                elapsedMilliseconds: EditorFindPerformanceSupport.milliseconds(
                    from: start,
                    to: end
                ),
                retainedMatchCount: session?.total ?? 0,
                isTruncated: session?.isTruncated ?? false,
                ranOffMain: controller.lastMatchRanOffMain
            ))
        }
        return observation
    }

    func assertSession(
        _ result: EditorFindPerformanceSupport.TimedSession,
        matches scenario: EditorFindPerformanceSupport.Scenario,
        label: String
    ) {
        XCTAssertEqual(result.retainedMatchCount, scenario.expectedRetainedMatchCount, label)
        XCTAssertEqual(result.isTruncated, scenario.expectedTruncation, label)
        XCTAssertTrue(result.ranOffMain, "\(label): production matcher must run off main")
    }

    func assertWallClockBudget(
        _ value: Double,
        lessThan budget: Double,
        metric: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard value < budget else {
            let message = String(
                format: "F2 PERF %@ %.3f ms exceeded %.3f ms budget",
                metric,
                value,
                budget
            )
            if EditorFindPerformanceSupport.isContinuousIntegration {
                print("\(message) on CI; informational per risk R15")
            } else {
                XCTFail(message, file: file, line: line)
            }
            return
        }
    }
}
