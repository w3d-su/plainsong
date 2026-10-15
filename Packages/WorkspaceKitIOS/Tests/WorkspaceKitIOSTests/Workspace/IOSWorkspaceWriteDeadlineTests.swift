import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSWorkspaceWriteDeadlineTests: XCTestCase {
    func testDeadlineNilIdentityLateSuccessRetainsTheLeaf() async throws {
        try await assertLateWrite(identity: nil, unreadable: false, cancel: false, remaining: Data([1, 1, 1]))
    }

    func testDeadlineNilIdentityLateUnreadableRetainsTheLeaf() async throws {
        try await assertLateWrite(identity: nil, unreadable: true, cancel: false, remaining: Data([2, 2, 2]))
    }

    func testDeadlineProvedIdentityLateSuccessRemovesTheLeaf() async throws {
        try await assertLateWrite(identity: Data("proved".utf8), unreadable: false, cancel: false, remaining: nil)
    }

    func testDeadlineProvedIdentityLateUnreadableRemovesTheLeaf() async throws {
        try await assertLateWrite(identity: Data("proved".utf8), unreadable: true, cancel: false, remaining: nil)
    }

    func testCancelNilIdentityLateSuccessRetainsTheLeaf() async throws {
        try await assertLateWrite(identity: nil, unreadable: false, cancel: true, remaining: Data([3, 3, 3]))
    }

    func testCancelNilIdentityLateUnreadableRetainsTheLeaf() async throws {
        try await assertLateWrite(identity: nil, unreadable: true, cancel: true, remaining: Data([4, 4, 4]))
    }

    func testCancelProvedIdentityLateSuccessRemovesTheLeaf() async throws {
        try await assertLateWrite(identity: Data("proved".utf8), unreadable: false, cancel: true, remaining: nil)
    }

    func testCancelProvedIdentityLateUnreadableRemovesTheLeaf() async throws {
        try await assertLateWrite(identity: Data("proved".utf8), unreadable: true, cancel: true, remaining: nil)
    }

    func testDeadlineReturnsAReceiptWhileCreateStaysParked() async throws {
        let harness = AccessHarness(coordinationTimeoutNanoseconds: 300_000_000)
        let grant = try await harness.openDirectory()
        let bytes = Data([5, 5, 5])
        harness.files.mintedIdentity = { _ in nil }
        harness.files.parkAfterPersist = true
        let outcome = try await parkedCreate(harness: harness, grant: grant, bytes: bytes)
        assertRetained(outcome)
        XCTAssertEqual(harness.files.parkedCreateCount, 1)
        XCTAssertEqual(harness.files.bytes(for: assetPath), bytes)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 1)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.consumerCount, 0)
        _ = harness.service.invalidate(grant.workspaceID)
        XCTAssertEqual(harness.scope.endCount, 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(harness.scope.endCount, 0)
        XCTAssertEqual(harness.files.parkedCreateCount, 1)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 1)
    }

    func testLateCreateKeepsScopeWhileRemoveStaysParked() async throws {
        let harness = AccessHarness(coordinationTimeoutNanoseconds: 300_000_000)
        let grant = try await harness.openDirectory()
        let bytes = Data([6, 6, 6])
        harness.files.mintedIdentity = { _ in Data("proved-late".utf8) }
        harness.files.parkAfterPersist = true
        harness.files.parkRemoves = true
        let outcome = try await parkedCreate(harness: harness, grant: grant, bytes: bytes)
        assertRetained(outcome)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 1)
        _ = harness.service.invalidate(grant.workspaceID)
        XCTAssertEqual(harness.scope.endCount, 0)
        harness.files.resumeCreate()
        await waitUntil { harness.files.parkedRemoveCount == 1 }
        XCTAssertEqual(harness.files.parkedRemoveCount, 1)
        XCTAssertEqual(harness.files.bytes(for: assetPath), bytes)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 1)
        XCTAssertEqual(harness.scope.endCount, 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(harness.scope.endCount, 0)
        XCTAssertEqual(harness.files.parkedRemoveCount, 1)
    }

    private func assertLateWrite(
        identity: Data?,
        unreadable: Bool,
        cancel: Bool,
        remaining: Data?
    ) async throws {
        let timeout: UInt64 = cancel ? 5_000_000_000 : 300_000_000
        let harness = AccessHarness(coordinationTimeoutNanoseconds: timeout)
        let grant = try await harness.openDirectory()
        let bytes = remaining ?? Data([9, 9, 9])
        harness.files.mintedIdentity = { _ in identity }
        harness.files.parkAfterPersist = true
        let outcome = StoredResult()
        let task = Task {
            do {
                _ = try await harness.service.stage(self.request(bytes: bytes, grant: grant), grant: grant)
                outcome.store(.success(()))
            } catch {
                outcome.store(.failure(error))
            }
        }
        await waitUntil { harness.files.parkedCreateCount == 1 }
        XCTAssertEqual(harness.files.bytes(for: assetPath), bytes)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 1)
        if cancel {
            task.cancel()
        }
        await waitUntil { outcome.result != nil }
        try assertRetained(XCTUnwrap(outcome.result))
        XCTAssertEqual(harness.files.bytes(for: assetPath), bytes)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 1)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.consumerCount, 0)
        XCTAssertEqual(harness.files.parkedCreateCount, 1)
        if unreadable {
            harness.files.resumeCreateUnreadable()
        } else {
            harness.files.resumeCreate()
        }
        await waitUntil { harness.service.records[grant.workspaceID]?.operationCount == 0 }
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 0)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.consumerCount, 0)
        XCTAssertEqual(harness.files.bytes(for: assetPath), remaining)
        _ = task
    }

    private func parkedCreate(
        harness: AccessHarness,
        grant: IOSWorkspaceGrant,
        bytes: Data
    ) async throws -> Result<Void, Error> {
        let outcome = StoredResult()
        let task = Task {
            do {
                _ = try await harness.service.stage(self.request(bytes: bytes, grant: grant), grant: grant)
                outcome.store(.success(()))
            } catch {
                outcome.store(.failure(error))
            }
        }
        await waitUntil { harness.files.parkedCreateCount == 1 }
        await waitUntil { outcome.result != nil }
        _ = task
        return try XCTUnwrap(outcome.result)
    }

    private func assertRetained(_ result: Result<Void, Error>) {
        guard case let .failure(error) = result,
              let failure = error as? IOSAssetStageFailure,
              case .retained = failure
        else {
            XCTFail("persisted leaf had no receipt: \(result)")
            return
        }
        XCTAssertFalse(error is CancellationError)
    }

    private let assetPath = "notes/assets/hero.png"

    private func request(bytes: Data, grant: IOSWorkspaceGrant) -> IOSImageAssetRequest {
        IOSImageAssetRequest(
            operationID: UUID(),
            bytes: bytes,
            contentType: "image/png",
            preferredFilename: "hero.png",
            destination: IOSFileLocation(
                workspaceID: grant.workspaceID,
                accessGeneration: grant.accessGeneration,
                relativePath: "notes/post.md",
                fileURL: IOSWorkspacePathAuthority.fileURL(
                    path: IOSWorkspacePathAuthority.joined(root: grant.rootURL, relativePath: "notes/post.md")
                ),
                resourceID: nil
            )
        )
    }
}

private final class StoredResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Void, Error>?

    func store(_ result: Result<Void, Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    var result: Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
