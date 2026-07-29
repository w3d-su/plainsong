@testable import EditorKit
import Foundation
@testable import Plainsong
import XCTest

/// F2 production-shaped performance probes over the committed 1 MiB editor fixture.
///
/// Query timing retains the production 150 ms debounce and drives App's real query-change
/// entry point through `EditorFindController` to the applied App presentation. Edit timing
/// hosts the shipped `WorkspaceWindow`, editor, and find-bar view tree, then records when
/// that root accepts the invalidated AppState snapshot. The timed receipt does not imply
/// child layout completion, compositor presentation, or physical-keystroke evidence.
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

    func testProductionWorkspaceFindOpenEditAdmissionAndStateReceiptStayWithinMeasuredBudgets()
        async throws
    {
        let fixture = try EditorFindPerformanceSupport.fixtureText(
            testBundle: Bundle(for: Self.self)
        )
        let harness = try await EditorFindPerformanceSupport.makeHostedWorkspaceHarness(
            fixtureText: fixture
        )
        do {
            try await runProductionWorkspaceEditProbe(in: harness)
            await harness.cleanUp()
        } catch {
            await harness.cleanUp()
            throw error
        }
    }
}

extension EditorFindPerformanceTests {
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
}

extension EditorFindPerformanceTests {
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
                ranOffMain: controller.lastMatchRanOffMain,
                firstMatch: session?.matches.first.map {
                    EditorFindPerformanceSupport.ExpectedMatchEndpoint(
                        range: $0.range,
                        line: $0.line
                    )
                },
                lastRetainedMatch: session?.matches.last.map {
                    EditorFindPerformanceSupport.ExpectedMatchEndpoint(
                        range: $0.range,
                        line: $0.line
                    )
                }
            ))
        }
        return observation
    }

    func assertSession(
        _ result: EditorFindPerformanceSupport.TimedSession,
        matches scenario: EditorFindPerformanceSupport.Scenario,
        label: String,
        sourceOffsetUTF16: Int = 0
    ) {
        XCTAssertEqual(result.retainedMatchCount, scenario.expectedRetainedMatchCount, label)
        XCTAssertEqual(result.isTruncated, scenario.expectedTruncation, label)
        XCTAssertEqual(
            result.firstMatch,
            scenario.expectedFirstMatch?.shifted(byUTF16: sourceOffsetUTF16),
            "\(label): first retained match moved"
        )
        XCTAssertEqual(
            result.lastRetainedMatch,
            scenario.expectedLastRetainedMatch?.shifted(byUTF16: sourceOffsetUTF16),
            "\(label): last retained match moved"
        )
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
