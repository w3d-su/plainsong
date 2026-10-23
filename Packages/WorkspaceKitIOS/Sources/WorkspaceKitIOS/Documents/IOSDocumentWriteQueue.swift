import Foundation

/// Issues at most one provider save at a time. A later save waits until the earlier
/// completion has been applied. Cancelling the caller does not cancel the provider write.
@MainActor
final class IOSDocumentWriteQueue {
    private var tail: Task<Void, Never>?

    func enqueue(_ body: @escaping @MainActor () async -> Void) {
        let previous = tail
        let next = Task { @MainActor in
            await previous?.value
            await Task.yield()
            await body()
        }
        tail = next
    }

    func drain() async {
        await tail?.value
    }
}
