import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSWorkspaceCoordinationDeadlineTests: XCTestCase {
    func testBlockingPresenterHitsThePortDeadlineWithoutRunningTheReader() async throws {
        let root = try temporaryRoot()
        let file = root.appendingPathComponent("Note.md")
        try Data("local".utf8).write(to: file)
        let presenter = StallPresenter(url: file)
        NSFileCoordinator.addFilePresenter(presenter)
        defer {
            presenter.release()
            NSFileCoordinator.removeFilePresenter(presenter)
            try? FileManager.default.removeItem(at: root)
        }
        var port = IOSSystemWorkspaceFilePort(timeoutNanoseconds: 5_000_000_000)
        presenter.releaseImmediately = true
        let primed = try await port.readFile(url: file, relativePath: "Note.md", maximumByteCount: 32, root: root)
        XCTAssertEqual(primed.data, Data("local".utf8))
        XCTAssertTrue(presenter.didDeliverReader)
        presenter.reset()
        presenter.releaseImmediately = false
        port.timeoutNanoseconds = 300_000_000
        let safety = Task {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            presenter.safetyRelease()
        }
        defer { safety.cancel() }
        let started = Date()
        do {
            _ = try await port.readFile(url: file, relativePath: "Note.md", maximumByteCount: 32, root: root)
            XCTFail("stalled read returned bytes")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
            XCTAssertFalse(presenter.safetyDidRelease)
            XCTAssertFalse(presenter.didDeliverReader)
            XCTAssertTrue(failure == .unavailable || failure == .coordinationFailed)
        }
    }

    func testCancellingABlockedCoordinateReturnsBeforeThePresenter() async throws {
        let root = try temporaryRoot()
        let file = root.appendingPathComponent("Note.md")
        try Data("local".utf8).write(to: file)
        let presenter = StallPresenter(url: file)
        NSFileCoordinator.addFilePresenter(presenter)
        defer {
            presenter.release()
            NSFileCoordinator.removeFilePresenter(presenter)
            try? FileManager.default.removeItem(at: root)
        }
        let port = IOSSystemWorkspaceFilePort(timeoutNanoseconds: 30_000_000_000)
        let safety = Task {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            presenter.safetyRelease()
        }
        defer { safety.cancel() }
        let outcome = ReadOutcome()
        let started = Date()
        let task = Task {
            do {
                _ = try await port.readFile(url: file, relativePath: "Note.md", maximumByteCount: 32, root: root)
                outcome.store(.success(Data()))
            } catch {
                outcome.store(.failure(error))
            }
        }
        await waitUntil { presenter.isStalling }
        task.cancel()
        await waitUntil { outcome.result != nil }
        XCTAssertNotNil(outcome.result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertFalse(presenter.safetyDidRelease)
        XCTAssertFalse(presenter.didDeliverReader)
        if case let .failure(error) = outcome.result {
            XCTAssertTrue(error is IOSWorkspaceFailure || error is CancellationError)
        } else {
            XCTFail("cancelled coordinate returned bytes")
        }
    }

    func testCallerDeadlineFencesLateBytesUntilTheReadDrains() async throws {
        let harness = AccessHarness(coordinationTimeoutNanoseconds: 300_000_000)
        let grant = try await harness.openDirectory()
        let lease = try harness.service.acquireLease(for: grant)
        harness.files.parkReads = true
        let outcome = ReadOutcome()
        let task = Task {
            do {
                let value = try await harness.service.read(
                    harness.location(grant: grant, relativePath: "Note.md"),
                    lease: lease,
                    operationID: UUID(),
                    maximumByteCount: 32
                )
                outcome.store(.success(value.data))
            } catch {
                outcome.store(.failure(error))
            }
        }
        await waitUntil { harness.files.parkedReadCount == 1 }
        await waitUntil { outcome.result != nil }
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 1)
        guard case let .failure(error) = outcome.result else {
            XCTFail("deadline returned the parked read")
            return
        }
        XCTAssertEqual(error as? IOSWorkspaceFailure, .coordinationFailed)
        harness.files.resumeRead(.success(Data("secret".utf8)))
        await waitUntil { harness.service.records[grant.workspaceID]?.operationCount == 0 }
        guard case let .failure(after) = outcome.result else {
            XCTFail("late bytes replaced the deadline")
            return
        }
        XCTAssertEqual(after as? IOSWorkspaceFailure, .coordinationFailed)
        _ = task
        lease.release()
    }

    func testTaskCancelDrainsOnlyAfterThePortReturns() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        let lease = try harness.service.acquireLease(for: grant)
        harness.files.parkReads = true
        let outcome = ReadOutcome()
        let task = Task {
            do {
                let value = try await harness.service.read(
                    harness.location(grant: grant, relativePath: "Note.md"),
                    lease: lease,
                    operationID: UUID(),
                    maximumByteCount: 32
                )
                outcome.store(.success(value.data))
            } catch {
                outcome.store(.failure(error))
            }
        }
        await waitUntil { harness.files.parkedReadCount == 1 }
        lease.release()
        _ = harness.service.invalidate(grant.workspaceID)
        XCTAssertEqual(harness.scope.endCount, 0)
        task.cancel()
        await waitUntil { outcome.result != nil }
        XCTAssertTrue(outcome.result?.error is CancellationError)
        XCTAssertEqual(harness.scope.endCount, 0)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 1)
        harness.files.resumeRead(.success(Data("late".utf8)))
        await waitUntil { harness.scope.endCount == 1 }
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 0)
        XCTAssertTrue(outcome.result?.error is CancellationError)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsong-lane06-deadline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private final class ReadOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Data, Error>?

    func store(_ result: Result<Data, Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    var result: Result<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private extension Result where Failure == Error {
    var error: Error? {
        if case let .failure(error) = self {
            return error
        }
        return nil
    }
}

private final class StallPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    var releaseImmediately = false
    private let lock = NSLock()
    private var reader: (@Sendable () -> Void)?
    private var delivered = false
    private var stalling = false
    private var safety = false

    init(url: URL) {
        presentedItemURL = url
        super.init()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue.name = "plainsong.lane06.stall"
    }

    func relinquishPresentedItem(toReader reader: @escaping (@Sendable ((@Sendable () -> Void)?) -> Void)) {
        if releaseImmediately {
            reader(nil)
            lock.lock()
            delivered = true
            lock.unlock()
            return
        }
        lock.lock()
        stalling = true
        self.reader = { reader(nil) }
        lock.unlock()
    }

    func release() {
        lock.lock()
        let reader = reader
        self.reader = nil
        if reader != nil {
            delivered = true
        }
        lock.unlock()
        reader?()
    }

    func safetyRelease() {
        lock.lock()
        safety = true
        lock.unlock()
        release()
    }

    func reset() {
        lock.lock()
        reader = nil
        delivered = false
        stalling = false
        safety = false
        lock.unlock()
    }

    var didDeliverReader: Bool {
        lock.lock()
        defer { lock.unlock() }
        return delivered
    }

    var isStalling: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stalling
    }

    var safetyDidRelease: Bool {
        lock.lock()
        defer { lock.unlock() }
        return safety
    }
}
