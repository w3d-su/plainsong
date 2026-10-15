import Foundation

/// Isolated Thread Sanitizer driver. It compiles against one copy of
/// `BoundedWait.swift` and is not an XCTest run.
@main
enum BoundedWaitRaceProbe {
    static func main() async {
        await preCancel(80)
        await cancelDuringWait(40)
        await deadlinePublication(80)
        print("PROBE_DONE")
    }

    private static func preCancel(_ count: Int) async {
        for _ in 0 ..< count {
            let parked = Park()
            let task = Task {
                try await BoundedWait.until(timeoutNanoseconds: 2_000_000_000) {
                    await Task.yield()
                    return await parked.park()
                }
            }
            task.cancel()
            _ = await task.result
            parked.release(true)
        }
    }

    private static func cancelDuringWait(_ count: Int) async {
        for _ in 0 ..< count {
            let parked = Park()
            let entered = Signal()
            let task = Task {
                try await BoundedWait.until(timeoutNanoseconds: 2_000_000_000) {
                    entered.signal()
                    return await parked.park()
                }
            }
            await entered.wait()
            task.cancel()
            _ = await task.result
            parked.release(true)
        }
    }

    private static func deadlinePublication(_ count: Int) async {
        for _ in 0 ..< count {
            let task = Task {
                try await BoundedWait.until(timeoutNanoseconds: 2_000_000) {
                    while !Task.isCancelled {
                        await Task.yield()
                    }
                    return true
                }
            }
            _ = await task.result
        }
    }
}

private final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false

    func signal() {
        lock.lock()
        signaled = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }
}

private final class Park: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var value: Bool?

    func park() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let value {
                lock.unlock()
                continuation.resume(returning: value)
                return
            }
            self.continuation = continuation
            lock.unlock()
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
