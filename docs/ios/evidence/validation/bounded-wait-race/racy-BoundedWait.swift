import Foundation

public enum BoundedWaitError: Error, Equatable {
    case timedOut(nanoseconds: UInt64)
}

public enum BoundedWait {
    /// Accepts `true` only when that result is observed before the deadline.
    ///
    /// The in-flight predicate is cancelled when the deadline passes or the caller
    /// is cancelled. A later `true` is discarded, including one that was already
    /// running when the deadline elapsed. A predicate that never returns does not
    /// keep the wait open. `pollNanoseconds` is only the pause after `false`, and
    /// it cannot extend the deadline.
    public static func until(
        timeoutNanoseconds: UInt64,
        pollNanoseconds: UInt64 = 5_000_000,
        predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        guard let timeout = Int64(exactly: timeoutNanoseconds) else {
            throw BoundedWaitError.timedOut(nanoseconds: timeoutNanoseconds)
        }
        let deadline = clock.now.advanced(by: .nanoseconds(timeout))
        let poll = Int64(exactly: pollNanoseconds).map { max(Int64(0), $0) } ?? Int64.max
        while true {
            try Task.checkCancellation()
            if clock.now >= deadline {
                throw BoundedWaitError.timedOut(nanoseconds: timeoutNanoseconds)
            }
            let attempt = await AttemptRace.run(predicate: predicate, deadline: deadline)
            try Task.checkCancellation()
            // A true that lands on or after the deadline is a late result.
            if clock.now >= deadline {
                throw BoundedWaitError.timedOut(nanoseconds: timeoutNanoseconds)
            }
            switch attempt {
            case .ready(true):
                return
            case .ready(false):
                let remaining = deadline - clock.now
                if remaining <= .zero {
                    throw BoundedWaitError.timedOut(nanoseconds: timeoutNanoseconds)
                }
                let slice = min(Duration.nanoseconds(poll), remaining)
                if slice <= .zero {
                    throw BoundedWaitError.timedOut(nanoseconds: timeoutNanoseconds)
                }
                try await clock.sleep(for: slice)
            case .expired:
                throw BoundedWaitError.timedOut(nanoseconds: timeoutNanoseconds)
            case .cancelled:
                throw CancellationError()
            }
        }
    }
}

private enum WaitAttempt: Sendable {
    case ready(Bool)
    case expired
    case cancelled
}

/// One predicate attempt raced against the deadline. The continuation resumes
/// once. Cancellation and the timer both drop a result that arrives afterwards.
private final class AttemptRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WaitAttempt, Never>?
    private var predicateTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var finished = false

    static func run(
        predicate: @escaping @Sendable () async -> Bool,
        deadline: ContinuousClock.Instant
    ) async -> WaitAttempt {
        let race = AttemptRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.begin(continuation, predicate: predicate, deadline: deadline)
            }
        } onCancel: {
            race.finish(.cancelled)
        }
    }

    private func begin(
        _ continuation: CheckedContinuation<WaitAttempt, Never>,
        predicate: @escaping @Sendable () async -> Bool,
        deadline: ContinuousClock.Instant
    ) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(returning: .cancelled)
            return
        }
        self.continuation = continuation
        lock.unlock()

        let predicateTask = Task { [self] in
            let value = await predicate()
            finish(Task.isCancelled ? .expired : .ready(value))
        }
        let timerTask = Task { [self] in
            let clock = ContinuousClock()
            let remaining = deadline - clock.now
            if remaining > .zero {
                try? await clock.sleep(for: remaining)
            }
            self.predicateTask?.cancel()
            finish(.expired)
        }
        lock.lock()
        self.predicateTask = predicateTask
        self.timerTask = timerTask
        let stop = finished
        lock.unlock()
        if stop {
            predicateTask.cancel()
            timerTask.cancel()
        }
    }

    private func finish(_ attempt: WaitAttempt) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let predicateTask = predicateTask
        let timerTask = timerTask
        lock.unlock()
        predicateTask?.cancel()
        timerTask?.cancel()
        continuation?.resume(returning: attempt)
    }
}
