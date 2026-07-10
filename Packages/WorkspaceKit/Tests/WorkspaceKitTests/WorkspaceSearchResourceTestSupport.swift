import Foundation
@testable import WorkspaceKit

struct MissingContractReader: WorkspaceSearchFileReading {
    func readFile(at _: URL, maximumByteCount _: Int) async throws -> Data {
        throw WorkspaceSearchFileReadError.disappeared
    }
}

struct MixedContractReader: WorkspaceSearchFileReading {
    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        if url.lastPathComponent.hasPrefix(".") {
            throw WorkspaceSearchFileReadError.disappeared
        }
        if url.lastPathComponent.hasPrefix("skip-") {
            return Data([0xFF].prefix(maximumByteCount))
        }
        return Data("needle".utf8.prefix(maximumByteCount))
    }
}

actor BulkReadWindowReader: WorkspaceSearchFileReading {
    private let firstPath: String
    private let firstDelayNanoseconds: UInt64
    private var activeReads = 0
    private var maximumActiveReads = 0
    private var candidateStarts = 0
    private var fastCompletions = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var completionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var noActiveReadWaiters: [CheckedContinuation<Void, Never>] = []

    init(firstPath: String, firstDelayNanoseconds: UInt64) {
        self.firstPath = firstPath
        self.firstDelayNanoseconds = firstDelayNanoseconds
    }

    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        if url.lastPathComponent.hasPrefix(".") {
            throw WorkspaceSearchFileReadError.disappeared
        }

        candidateStarts += 1
        resumeStartWaiters()
        activeReads += 1
        maximumActiveReads = max(maximumActiveReads, activeReads)
        defer {
            activeReads -= 1
            if activeReads == 0 {
                let waiters = noActiveReadWaiters
                noActiveReadWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }

        if url.lastPathComponent == firstPath {
            try await Task.sleep(nanoseconds: firstDelayNanoseconds)
        } else {
            fastCompletions += 1
            resumeCompletionWaiters()
        }
        return Data("needle \(url.lastPathComponent)".utf8.prefix(maximumByteCount))
    }

    func waitUntilCandidateStartCount(_ count: Int) async {
        if candidateStarts >= count { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func waitUntilFastCompletionCount(_ count: Int) async {
        if fastCompletions >= count { return }
        await withCheckedContinuation { continuation in
            completionWaiters.append((count, continuation))
        }
    }

    func waitUntilNoActiveReads() async {
        if activeReads == 0 { return }
        await withCheckedContinuation { continuation in
            noActiveReadWaiters.append(continuation)
        }
    }

    func activeReadCount() -> Int {
        activeReads
    }

    func maximumActiveReadCount() -> Int {
        maximumActiveReads
    }

    func candidateStartCount() -> Int {
        candidateStarts
    }

    private func resumeStartWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in startWaiters {
            if candidateStarts >= target {
                continuation.resume()
            } else {
                remaining.append((target, continuation))
            }
        }
        startWaiters = remaining
    }

    private func resumeCompletionWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in completionWaiters {
            if fastCompletions >= target {
                continuation.resume()
            } else {
                remaining.append((target, continuation))
            }
        }
        completionWaiters = remaining
    }
}

extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
