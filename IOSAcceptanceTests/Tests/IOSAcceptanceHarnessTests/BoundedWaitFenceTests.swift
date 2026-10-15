import Foundation
@testable import IOSAcceptanceHarness
import XCTest

final class BoundedWaitFenceTests: XCTestCase {
    func testZeroTimeoutDoesNotAcceptAnImmediateTrue() async {
        do {
            try await BoundedWait.until(timeoutNanoseconds: 0) { true }
            XCTFail("deadline was accepted after it had already passed")
        } catch let error as BoundedWaitError {
            XCTAssertEqual(error, .timedOut(nanoseconds: 0))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTrueBeforeTheDeadlineIsAccepted() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        try await BoundedWait.until(timeoutNanoseconds: 500_000_000, pollNanoseconds: 5_000_000) {
            await Self.pause(seconds: 0.015)
            return true
        }
        XCTAssertLessThan(clock.now - start, .milliseconds(400))
    }

    func testDelayedTruePastTheDeadlineIsRejected() async {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await BoundedWait.until(timeoutNanoseconds: 20_000_000, pollNanoseconds: 5_000_000) {
                await Self.pause(seconds: 0.25)
                return true
            }
            XCTFail("true after the deadline was accepted")
        } catch let error as BoundedWaitError {
            XCTAssertEqual(error, .timedOut(nanoseconds: 20_000_000))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertLessThan(clock.now - start, .milliseconds(150))
    }

    func testSilentPredicateTimesOutBeforeALateTrue() async {
        let parked = ParkedPredicate()
        Thread {
            Thread.sleep(forTimeInterval: 0.25)
            parked.release(true)
        }.start()
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await BoundedWait.until(timeoutNanoseconds: 20_000_000, pollNanoseconds: 5_000_000) {
                await parked.park()
            }
            XCTFail("a predicate that had not replied was accepted")
        } catch let error as BoundedWaitError {
            XCTAssertEqual(error, .timedOut(nanoseconds: 20_000_000))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertLessThan(clock.now - start, .milliseconds(150))
    }

    private static func pause(seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                Thread.sleep(forTimeInterval: seconds)
                continuation.resume()
            }
            thread.start()
        }
    }
}

private final class ParkedPredicate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var value: Bool?

    func park() async -> Bool {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            if let value = self.value {
                self.lock.unlock()
                continuation.resume(returning: value)
                return
            }
            self.continuation = continuation
            self.lock.unlock()
        }
    }

    func release(_ value: Bool) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            self.value = value
        }
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
