import Foundation

public enum BoundedWaitError: Error, Equatable {
    case timedOut(nanoseconds: UInt64)
}

public enum BoundedWait {
    /// Polls until the predicate is true or the deadline passes. A timeout is a
    /// typed failure. The wait does not continue until a later success.
    public static func until(
        timeoutNanoseconds: UInt64,
        pollNanoseconds: UInt64 = 5_000_000,
        predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
        while true {
            if await predicate() { return }
            if clock.now >= deadline {
                throw BoundedWaitError.timedOut(nanoseconds: timeoutNanoseconds)
            }
            let remaining = deadline - clock.now
            let slice = min(Duration.nanoseconds(Int64(pollNanoseconds)), remaining)
            if slice <= .zero { throw BoundedWaitError.timedOut(nanoseconds: timeoutNanoseconds) }
            try await clock.sleep(for: slice)
        }
    }
}
