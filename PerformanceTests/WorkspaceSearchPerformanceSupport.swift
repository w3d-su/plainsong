import Foundation
import MarkdownCore
import WorkspaceKit
import XCTest

// MARK: - Request and stream helpers

struct SearchRun {
    let events: [WorkspaceSearchEvent]
    let elapsedMilliseconds: Double
}

extension WorkspaceSearchPerformanceTests {
    func makeRequest(
        capture: WorkspaceDirectorySnapshotCapture,
        rootIdentity: String,
        query: TextSearchQuery,
        queryGeneration: UInt64 = 1
    ) throws -> WorkspaceSearchRequest {
        WorkspaceSearchRequest(
            rootAuthority: capture.rootAuthority,
            rootIdentity: rootIdentity,
            snapshot: capture.snapshot,
            workspaceGeneration: 1,
            queryGeneration: queryGeneration,
            query: query
        )
    }

    /// Consumes the complete stream from the production disk reader and returns wall-clock
    /// time for the whole request, including candidate planning and terminal delivery.
    func collect(request: WorkspaceSearchRequest) async throws -> SearchRun {
        // `WorkspaceSearchService()` selects the production `WorkspaceSearchDiskFileReader`.
        // It is constructed before the clock starts so only request work is measured.
        let service = WorkspaceSearchService()
        let start = DispatchTime.now().uptimeNanoseconds
        var events: [WorkspaceSearchEvent] = []
        for await event in service.events(for: request) {
            events.append(event)
        }
        let elapsed = Self.milliseconds(since: start)
        return SearchRun(events: events, elapsedMilliseconds: elapsed)
    }
}

// MARK: - Event and timing helpers

extension WorkspaceSearchPerformanceTests {
    func fileResults(in events: [WorkspaceSearchEvent]) -> [WorkspaceSearchFileResult] {
        events.compactMap { event in
            guard case let .fileResult(_, result) = event else { return nil }
            return result
        }
    }

    func skippedFiles(in events: [WorkspaceSearchEvent]) -> [WorkspaceSearchSkippedFile] {
        events.compactMap { event in
            guard case let .skippedFile(_, skipped) = event else { return nil }
            return skipped
        }
    }

    func progressEvents(in events: [WorkspaceSearchEvent]) -> [WorkspaceSearchProgress] {
        events.compactMap { event in
            guard case let .progress(_, progress) = event else { return nil }
            return progress
        }
    }

    func completedSummaries(in events: [WorkspaceSearchEvent]) -> [WorkspaceSearchSummary] {
        events.compactMap { event in
            guard case let .completed(_, summary) = event else { return nil }
            return summary
        }
    }

    func failures(in events: [WorkspaceSearchEvent]) -> [WorkspaceSearchServiceFailure] {
        events.compactMap { event in
            guard case let .failed(_, failure) = event else { return nil }
            return failure
        }
    }

    func terminalEventCount(in events: [WorkspaceSearchEvent]) -> Int {
        events.reduce(into: 0) { count, event in
            switch event {
            case .completed, .failed:
                count += 1
            case .fileResult, .skippedFile, .progress, .validationFailure:
                break
            }
        }
    }

    func assertSearchBudget(
        _ value: Double,
        lessThan budget: Double,
        metric: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard value >= budget else { return }
        let message = String(
            format: "WS4B PERF %@ %.3f ms exceeded %.3f ms budget",
            metric,
            value,
            budget
        )
        if Self.isContinuousIntegration {
            print("\(message) on CI; informational per risk R15")
            return
        }
        XCTFail(message, file: file, line: line)
    }

    private static var isContinuousIntegration: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CI"] == "true" || environment["GITHUB_ACTIONS"] == "true"
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    static func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    static func formatSamples(_ samples: [Double]) -> String {
        "[" + samples.map { String(format: "%.3f", $0) }.joined(separator: ", ") + "]"
    }
}
