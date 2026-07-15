import Foundation
@testable import WorkspaceKit

protocol SyntheticWorkspaceSearchFileReading: WorkspaceSearchFileReading {}

extension SyntheticWorkspaceSearchFileReading {
    func physicalPreflightError(at _: URL) -> WorkspaceSearchFileReadError? {
        nil
    }

    func validateFile(at _: WorkspaceFileSystemLocation) async throws {}

    func readFile(
        at location: WorkspaceFileSystemLocation,
        maximumByteCount: Int
    ) async throws -> Data {
        try await readFile(at: location.fileURL, maximumByteCount: maximumByteCount)
    }
}

struct MissingContractReader: SyntheticWorkspaceSearchFileReading {
    func readFile(at _: URL, maximumByteCount _: Int) async throws -> Data {
        throw WorkspaceSearchFileReadError.disappeared
    }
}

struct MixedContractReader: SyntheticWorkspaceSearchFileReading {
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

actor BulkReadWindowReader: SyntheticWorkspaceSearchFileReading {
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

actor GlobalTruncationAccountingReader: SyntheticWorkspaceSearchFileReading {
    static let overflowText = "needle needle needle"
    static let validText = "needle after cap"

    private var activeReads = 0
    private var maximumActiveReads = 0
    private var candidateStarts = 0
    private var readsByFilename: [String: Int] = [:]

    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        let filename = url.lastPathComponent
        if filename.hasPrefix(".") {
            throw WorkspaceSearchFileReadError.disappeared
        }

        candidateStarts += 1
        readsByFilename[filename, default: 0] += 1
        activeReads += 1
        maximumActiveReads = max(maximumActiveReads, activeReads)
        defer { activeReads -= 1 }

        switch filename {
        case "000-overflow.md":
            try await Task.sleep(nanoseconds: 50_000_000)
            return Data(Self.overflowText.utf8.prefix(maximumByteCount))
        case "100-disappeared.md":
            throw WorkspaceSearchFileReadError.disappeared
        case "200-unreadable.md":
            throw WorkspaceSearchFileReadError.unreadable
        case "300-invalid.md":
            return Data([0xFF].prefix(maximumByteCount))
        case "400-oversized.md":
            return Data(repeating: 0x61, count: maximumByteCount)
        case "410-disappeared-omitted.md":
            throw WorkspaceSearchFileReadError.disappeared
        case "420-unreadable-omitted.md":
            throw WorkspaceSearchFileReadError.unreadable
        case "600-valid.md":
            return Data(Self.validText.utf8.prefix(maximumByteCount))
        default:
            throw WorkspaceSearchFileReadError.disappeared
        }
    }

    func candidateStartCount() -> Int {
        candidateStarts
    }

    func readCount(for filename: String) -> Int {
        readsByFilename[filename, default: 0]
    }

    func maximumActiveReadCount() -> Int {
        maximumActiveReads
    }
}

struct UnexpectedCancellationErrorReader: SyntheticWorkspaceSearchFileReading {
    func readFile(at url: URL, maximumByteCount _: Int) async throws -> Data {
        if url.lastPathComponent.hasPrefix(".") {
            throw WorkspaceSearchFileReadError.disappeared
        }
        throw CancellationError()
    }
}

actor BlockingCancellationReader: SyntheticWorkspaceSearchFileReading {
    private var activeReads = 0
    private var candidateStarts = 0
    private var cancelledReads = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var noActiveReadWaiters: [CheckedContinuation<Void, Never>] = []

    func readFile(at url: URL, maximumByteCount _: Int) async throws -> Data {
        if url.lastPathComponent.hasPrefix(".") {
            throw WorkspaceSearchFileReadError.disappeared
        }

        candidateStarts += 1
        activeReads += 1
        resumeStartWaiters()
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

        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return Data("needle".utf8)
        } catch let error as CancellationError {
            cancelledReads += 1
            throw error
        }
    }

    func waitUntilCandidateStartCount(_ count: Int) async {
        if candidateStarts >= count { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func waitUntilNoActiveReads() async {
        if activeReads == 0 { return }
        await withCheckedContinuation { continuation in
            noActiveReadWaiters.append(continuation)
        }
    }

    func candidateStartCount() -> Int {
        candidateStarts
    }

    func cancellationCount() -> Int {
        cancelledReads
    }

    func activeReadCount() -> Int {
        activeReads
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
}

extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
