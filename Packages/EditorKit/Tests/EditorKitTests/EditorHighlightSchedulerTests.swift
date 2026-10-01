@testable import EditorKit
import XCTest

@MainActor
final class EditorHighlightSchedulerTests: XCTestCase {
    func testRapidRestartsKeepOneInFlightAndApplyExactlyTheFinalRevision() async throws {
        let debounce = ManualGate()
        let scheduler = EditorHighlightScheduler(debounce: { await debounce.wait() })
        let recorder = ApplyRecorder()
        scheduler.restart(revision: 1) { recorder.applied.append($0) }
        try await waitUntil { debounce.arrivals == 1 }
        for revision in 2 ... 50 {
            scheduler.restart(revision: revision) { recorder.applied.append($0) }
        }
        // The gate deliberately ignores cancellation; even then no new task starts.
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertEqual(debounce.arrivals, 1)
        debounce.releaseAll()
        try await waitUntil { debounce.arrivals == 2 }
        XCTAssertEqual(debounce.results, [false])
        debounce.releaseAll()
        try await waitUntil { recorder.applied == [50] }
        XCTAssertEqual(debounce.results, [false, true])
        XCTAssertEqual(debounce.maximumInFlight, 1)
    }

    func testEveryStartedSupersededRequestIsCancelled() async throws {
        let debounce = ManualGate()
        let scheduler = EditorHighlightScheduler(debounce: { await debounce.wait() })
        let recorder = ApplyRecorder()
        scheduler.restart(revision: 1) { recorder.applied.append($0) }
        try await waitUntil { debounce.arrivals == 1 }
        for revision in 2 ... 50 {
            scheduler.restart(revision: revision) { recorder.applied.append($0) }
            debounce.releaseAll()
            try await waitUntil { debounce.arrivals == revision }
        }
        debounce.releaseAll()
        try await waitUntil { debounce.results.count == 50 }
        XCTAssertEqual(recorder.applied, [50])
        XCTAssertEqual(debounce.results.filter { !$0 }.count, 49)
        XCTAssertEqual(debounce.results.filter { $0 }.count, 1)
        XCTAssertEqual(debounce.maximumInFlight, 1)
    }

    func testSupersessionDuringParseWaitsForCancelledParseBeforeStartingFinalRequest() async throws {
        let parse = ManualGate()
        let scheduler = EditorHighlightScheduler(debounce: { true })
        let recorder = ApplyRecorder()
        let apply: @MainActor (Int) async -> Void = { revision in
            _ = await parse.wait()
            recorder.finishedCancelled[revision] = Task.isCancelled
            if !Task.isCancelled { recorder.applied.append(revision) }
        }
        scheduler.restart(revision: 1, apply: apply)
        try await waitUntil { parse.arrivals == 1 }
        for revision in 2 ... 50 {
            scheduler.restart(revision: revision, apply: apply)
        }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertEqual(parse.arrivals, 1)
        parse.releaseAll()
        try await waitUntil { parse.arrivals == 2 }
        parse.releaseAll()
        try await waitUntil { recorder.finishedCancelled.count == 2 }
        XCTAssertEqual(recorder.finishedCancelled, [1: true, 50: false])
        XCTAssertEqual(recorder.applied, [50])
        XCTAssertEqual(parse.maximumInFlight, 1)
    }

    func testCancelDropsBothExecutingAndPendingRequestsAndAllowsRestart() async throws {
        let debounce = ManualGate()
        let scheduler = EditorHighlightScheduler(debounce: { await debounce.wait() })
        let recorder = ApplyRecorder()
        scheduler.restart(revision: 1) { recorder.applied.append($0) }
        try await waitUntil { debounce.arrivals == 1 }
        scheduler.restart(revision: 2) { recorder.applied.append($0) }
        scheduler.cancel()
        debounce.releaseAll()
        try await waitUntil { debounce.results.count == 1 }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertEqual(debounce.arrivals, 1)
        XCTAssertEqual(recorder.applied, [])
        scheduler.restart(revision: 3) { recorder.applied.append($0) }
        try await waitUntil { debounce.arrivals == 2 }
        debounce.releaseAll()
        try await waitUntil { recorder.applied == [3] }
    }

    func testProductionDebounceAppliesOnlyTheFinalRevisionOfABurst() async throws {
        let scheduler = EditorHighlightScheduler()
        let recorder = ApplyRecorder()
        for revision in 1 ... 50 {
            scheduler.restart(revision: revision) { recorder.applied.append($0) }
        }
        try await waitUntil { !recorder.applied.isEmpty }
        try await Task.sleep(nanoseconds: 5 * MarkdownEditorView.highlightDebounceNanoseconds)
        XCTAssertEqual(recorder.applied, [50])
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) async throws {
        try await EditorFindControllerTestSupport.waitUntil(timeout: 5, predicate: predicate)
    }
}

@MainActor
private final class ApplyRecorder {
    var applied: [Int] = []
    var finishedCancelled: [Int: Bool] = [:]
}

/// Intentionally ignores cancellation until released, like an already-running parse.
@MainActor
private final class ManualGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0
    private(set) var results: [Bool] = []
    private(set) var maximumInFlight = 0

    func wait() async -> Bool {
        arrivals += 1
        await withCheckedContinuation {
            waiters.append($0)
            maximumInFlight = max(maximumInFlight, waiters.count)
        }
        let proceeds = !Task.isCancelled
        results.append(proceeds)
        return proceeds
    }

    func releaseAll() {
        let released = waiters
        waiters = []
        released.forEach { $0.resume() }
    }
}
