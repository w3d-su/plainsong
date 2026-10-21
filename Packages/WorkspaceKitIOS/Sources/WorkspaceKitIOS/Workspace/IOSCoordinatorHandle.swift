import Foundation

/// Cancels an in-flight `NSFileCoordinator` from the caller deadline without sharing the class across actors unsafely.
final class IOSCoordinatorHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var coordinator: NSFileCoordinator?
    private var cancelled = false

    func begin() -> NSFileCoordinator {
        let coordinator = NSFileCoordinator()
        lock.lock()
        self.coordinator = coordinator
        let cancelled = cancelled
        lock.unlock()
        if cancelled {
            coordinator.cancel()
        }
        return coordinator
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let coordinator = coordinator
        lock.unlock()
        coordinator?.cancel()
    }
}
