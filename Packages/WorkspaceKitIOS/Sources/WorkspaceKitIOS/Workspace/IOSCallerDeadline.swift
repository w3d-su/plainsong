import Foundation

/// The caller already observed this failure. `onDrain` finishes the operation after the port returns.
struct IOSDrainingCoordinationFailure: Error {
    var isCancellation: Bool
    var failure: IOSWorkspaceFailure
}

final class IOSOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed {
            return false
        }
        claimed = true
        return true
    }
}

final class IOSDrainGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func finish() {
        lock.lock()
        finished = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

/// Resumes the caller at the deadline or cancellation, then drains the port before `onDrain`.
enum IOSCallerDeadline {
    static func race<T: Sendable>(
        timeoutNanoseconds: UInt64,
        onDrain: @escaping @Sendable () async -> Void,
        body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = IOSDrainGate()
        let race = IOSDeadlineRace<T>()
        let operation = Task {
            defer { gate.finish() }
            return try await body()
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            guard race.claim(.failure(IOSDrainingCoordinationFailure(
                isCancellation: false,
                failure: .coordinationFailed
            ))) else {
                return
            }
            operation.cancel()
            await gate.wait()
            await onDrain()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.store(continuation)
                Task {
                    let result = await operation.result
                    timeoutTask.cancel()
                    _ = race.claim(result)
                }
            }
        } onCancel: {
            operation.cancel()
            timeoutTask.cancel()
            guard race.claim(.failure(IOSDrainingCoordinationFailure(
                isCancellation: true,
                failure: .unavailable
            ))) else {
                return
            }
            Task {
                await gate.wait()
                await onDrain()
            }
        }
    }
}

/// Stage already returned this failure. The drain still holds the lease until the port returns.
struct IOSStageLeaseHandoff: Error {
    var failure: IOSAssetStageFailure
}

extension IOSCallerDeadline {
    /// Resumes the caller at the deadline. `onDrain` observes the body result after that resume.
    static func raceDrained<T: Sendable>(
        timeoutNanoseconds: UInt64,
        onDrain: @escaping @Sendable (Result<T, Error>) async -> Void,
        body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = IOSDeadlineRace<T>()
        let operation = Task {
            try await body()
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            guard race.claim(.failure(IOSDrainingCoordinationFailure(
                isCancellation: false,
                failure: .coordinationFailed
            ))) else {
                return
            }
            operation.cancel()
            await onDrain(operation.result)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.store(continuation)
                Task {
                    let result = await operation.result
                    timeoutTask.cancel()
                    _ = race.claim(result)
                }
            }
        } onCancel: {
            operation.cancel()
            timeoutTask.cancel()
            guard race.claim(.failure(IOSDrainingCoordinationFailure(
                isCancellation: true,
                failure: .unavailable
            ))) else {
                return
            }
            Task {
                await onDrain(operation.result)
            }
        }
    }
}

/// One continuation, resumed by the first of success, failure, deadline, or cancellation.
private final class IOSDeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var claimed = false
    private var early: Result<T, Error>?

    func store(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if claimed, let early {
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    @discardableResult
    func claim(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        if claimed {
            lock.unlock()
            return false
        }
        claimed = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            early = result
        }
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}
