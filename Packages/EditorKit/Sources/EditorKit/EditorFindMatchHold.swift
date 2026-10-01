import Foundation

/// Test seam: holds off-main match work until `release()` so stale-completion races
/// can be made deterministic. Internal only (`@testable import`); not shipping API.
final class EditorFindMatchHold: @unchecked Sendable {
    private let lock = NSLock()
    private var isHeld = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    func waitIfHeld() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isHeld {
                waiters.append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        isHeld = false
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending {
            waiter.resume()
        }
    }
}
