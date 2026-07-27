import Foundation
import MarkdownCore
import WorkspaceKit
import XCTest

// Controlled reader used only by the cancellation probe.

// MARK: - Controlled reader for deterministic cancellation

/// Blocks every candidate read so the producer saturates exactly the configured window and
/// cancellation has deterministic work to drain. Ignore-policy probes for `.gitignore` /
/// `.ignore` resolve immediately as missing, exactly as they do in the real fixture, so the
/// blocked reads are candidate reads only.
actor BlockingSearchReader: WorkspaceSearchFileReading {
    /// Generous relative to the sub-millisecond behavior being measured, but bounded, so a
    /// regression fails this probe in seconds instead of stalling the whole test job.
    static let waitTimeoutNanoseconds: UInt64 = 10_000_000_000

    private var activeReads = 0
    private var startedReads = 0
    private var cancelledReads = 0
    private var nextWaiterID: UInt64 = 0
    private var startWaiters: [(UInt64, Int, CheckedContinuation<Bool, Never>)] = []
    private var idleWaiters: [(UInt64, CheckedContinuation<Bool, Never>)] = []

    nonisolated func physicalPreflightError(at _: URL) -> WorkspaceSearchFileReadError? {
        nil
    }

    nonisolated func validateFile(at _: WorkspaceFileSystemLocation) async throws {}

    nonisolated func validateFileAuthority(
        at _: WorkspaceFileSystemLocation
    ) async throws -> WorkspaceSearchFileAuthority? {
        nil
    }

    func readFile(at location: WorkspaceFileSystemLocation, maximumByteCount: Int) async throws -> Data {
        try await block(name: location.fileURL.lastPathComponent, maximumByteCount: maximumByteCount)
    }

    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        try await block(name: url.lastPathComponent, maximumByteCount: maximumByteCount)
    }

    func readFileWithAuthority(
        at location: WorkspaceFileSystemLocation,
        maximumByteCount: Int
    ) async throws -> WorkspaceSearchFileReadResult {
        let data = try await block(
            name: location.fileURL.lastPathComponent,
            maximumByteCount: maximumByteCount
        )
        return WorkspaceSearchFileReadResult(data: data, fileAuthority: nil)
    }

    /// Waits for the producer to start `count` reads, returning `false` if it has not done so
    /// within the deadline. Every read here blocks for a minute, so an unbounded wait would turn
    /// a window regression into a job-length hang instead of a test failure; the caller asserts
    /// on the result and stops rather than reporting a meaningless latency sample.
    func waitUntilStartCount(
        _ count: Int,
        timeoutNanoseconds: UInt64 = BlockingSearchReader.waitTimeoutNanoseconds
    ) async -> Bool {
        if startedReads >= count { return true }
        let id = nextWaiterID
        nextWaiterID += 1
        let expiry = expiryTask(for: id, timeoutNanoseconds: timeoutNanoseconds) { reader, id in
            await reader.expireStartWaiter(id)
        }
        defer { expiry.cancel() }
        return await withCheckedContinuation { continuation in
            startWaiters.append((id, count, continuation))
        }
    }

    /// Waits for every blocked read to unwind after cancellation, returning `false` on timeout
    /// for the same reason as `waitUntilStartCount(_:timeoutNanoseconds:)`.
    func waitUntilNoActiveReads(
        timeoutNanoseconds: UInt64 = BlockingSearchReader.waitTimeoutNanoseconds
    ) async -> Bool {
        if activeReads == 0 { return true }
        let id = nextWaiterID
        nextWaiterID += 1
        let expiry = expiryTask(for: id, timeoutNanoseconds: timeoutNanoseconds) { reader, id in
            await reader.expireIdleWaiter(id)
        }
        defer { expiry.cancel() }
        return await withCheckedContinuation { continuation in
            idleWaiters.append((id, continuation))
        }
    }

    private nonisolated func expiryTask(
        for id: UInt64,
        timeoutNanoseconds: UInt64,
        expire: @escaping @Sendable (BlockingSearchReader, UInt64) async -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled, let self else { return }
            await expire(self, id)
        }
    }

    /// Removing the waiter under actor isolation is what keeps the resume exactly-once: whichever
    /// of the satisfying path and the expiry path reaches the array first takes the continuation.
    private func expireStartWaiter(_ id: UInt64) {
        guard let index = startWaiters.firstIndex(where: { $0.0 == id }) else { return }
        let waiter = startWaiters.remove(at: index)
        waiter.2.resume(returning: false)
    }

    private func expireIdleWaiter(_ id: UInt64) {
        guard let index = idleWaiters.firstIndex(where: { $0.0 == id }) else { return }
        let waiter = idleWaiters.remove(at: index)
        waiter.1.resume(returning: false)
    }

    func startCount() -> Int {
        startedReads
    }

    func activeReadCount() -> Int {
        activeReads
    }

    func cancelledReadCount() -> Int {
        cancelledReads
    }

    private func block(name: String, maximumByteCount: Int) async throws -> Data {
        guard !name.hasPrefix(".") else {
            throw WorkspaceSearchFileReadError.disappeared
        }

        startedReads += 1
        activeReads += 1
        resumeStartWaiters()
        defer {
            activeReads -= 1
            if activeReads == 0 {
                let waiters = idleWaiters
                idleWaiters.removeAll()
                for waiter in waiters {
                    waiter.1.resume(returning: true)
                }
            }
        }

        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return Data("unreachable".utf8.prefix(max(0, maximumByteCount)))
        } catch {
            cancelledReads += 1
            throw error
        }
    }

    private func resumeStartWaiters() {
        var remaining: [(UInt64, Int, CheckedContinuation<Bool, Never>)] = []
        for waiter in startWaiters {
            if startedReads >= waiter.1 {
                waiter.2.resume(returning: true)
            } else {
                remaining.append(waiter)
            }
        }
        startWaiters = remaining
    }
}
