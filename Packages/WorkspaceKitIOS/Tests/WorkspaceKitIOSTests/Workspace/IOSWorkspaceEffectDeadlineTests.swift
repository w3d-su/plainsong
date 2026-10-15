import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSWorkspaceEffectDeadlineTests: XCTestCase {
    func testValidateDeadlineReturnsWhileMetadataStaysParked() async throws {
        let harness = AccessHarness(coordinationTimeoutNanoseconds: 300_000_000)
        let grant = try await harness.openDirectory()
        let staged = try await harness.service.stage(hero(grant: grant, bytes: Data([1])), grant: grant)
        harness.files.parkMetadata = true
        let outcome = StoredResult()
        let task = Task {
            do {
                try await harness.service.validate(staged)
                outcome.store(.success(()))
            } catch {
                outcome.store(.failure(error))
            }
        }
        await waitUntil { harness.files.parkedMetadataCount == 1 }
        await waitUntil { outcome.result != nil }
        XCTAssertEqual(outcome.result?.error as? IOSWorkspaceFailure, .coordinationFailed)
        XCTAssertEqual(harness.files.parkedMetadataCount, 1)
        harness.files.resumeMetadata()
        await waitUntil { harness.files.parkedMetadataCount == 0 }
        _ = task
    }

    func testValidateCancelReturnsWhileMetadataStaysParked() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        let staged = try await harness.service.stage(hero(grant: grant, bytes: Data([2])), grant: grant)
        harness.files.parkMetadata = true
        let outcome = StoredResult()
        let task = Task {
            do {
                try await harness.service.validate(staged)
                outcome.store(.success(()))
            } catch {
                outcome.store(.failure(error))
            }
        }
        await waitUntil { harness.files.parkedMetadataCount == 1 }
        task.cancel()
        await waitUntil { outcome.result != nil }
        XCTAssertTrue(outcome.result?.error is CancellationError)
        XCTAssertEqual(harness.files.parkedMetadataCount, 1)
        harness.files.resumeMetadata()
        await waitUntil { harness.files.parkedMetadataCount == 0 }
    }

    func testAdoptDeadlineEndsScopeOnlyAfterMetadataDrains() async throws {
        try await assertAdopt(cancel: false)
    }

    func testAdoptCancelEndsScopeOnlyAfterMetadataDrains() async throws {
        try await assertAdopt(cancel: true)
    }

    func testStageMetadataDeadlineHoldsTheLeaseUntilDrain() async throws {
        let harness = AccessHarness(coordinationTimeoutNanoseconds: 300_000_000)
        let grant = try await harness.openDirectory()
        harness.files.mintedIdentity = { _ in nil }
        harness.files.parkMetadata = true
        let bytes = Data([6, 6, 6])
        let outcome = try await parkedStage(harness: harness, grant: grant, bytes: bytes)
        XCTAssertEqual(harness.files.bytes(for: assetPath), bytes)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.consumerCount, 1)
        XCTAssertEqual(harness.scope.endCount, 0)
        guard case let .failure(error as IOSAssetStageFailure) = outcome, case .retained = error else {
            XCTFail("metadata deadline dropped the leaf: \(String(describing: outcome))")
            return
        }
        harness.files.resumeMetadata()
        await waitUntil { harness.service.records[grant.workspaceID]?.consumerCount == 0 }
        XCTAssertEqual(harness.files.bytes(for: assetPath), bytes)
        XCTAssertEqual(harness.scope.endCount, 0)
    }

    func testStageMetadataDeadlineRemovesAProvedLeafOnDrain() async throws {
        let harness = AccessHarness(coordinationTimeoutNanoseconds: 300_000_000)
        let grant = try await harness.openDirectory()
        harness.files.mintedIdentity = { _ in Data("proved-meta".utf8) }
        harness.files.parkMetadata = true
        let bytes = Data([7, 7, 7])
        let outcome = try await parkedStage(harness: harness, grant: grant, bytes: bytes)
        XCTAssertEqual(harness.files.bytes(for: assetPath), bytes)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.consumerCount, 1)
        guard case let .failure(error as IOSAssetStageFailure) = outcome, case .retained = error else {
            XCTFail("proved metadata deadline had no receipt: \(String(describing: outcome))")
            return
        }
        harness.files.resumeMetadata()
        await waitUntil { harness.service.records[grant.workspaceID]?.consumerCount == 0 }
        XCTAssertNil(harness.files.bytes(for: assetPath))
    }

    func testStageMetadataCancelHoldsTheLeaseUntilDrain() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        harness.files.mintedIdentity = { _ in nil }
        harness.files.parkMetadata = true
        let bytes = Data([8, 8, 8])
        let outcome = StoredResult()
        let task = Task {
            do {
                _ = try await harness.service.stage(self.hero(grant: grant, bytes: bytes), grant: grant)
                outcome.store(.success(()))
            } catch {
                outcome.store(.failure(error))
            }
        }
        await waitUntil { harness.files.parkedMetadataCount == 1 }
        task.cancel()
        await waitUntil { outcome.result != nil }
        XCTAssertEqual(harness.files.bytes(for: assetPath), bytes)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.consumerCount, 1)
        guard let result = outcome.result,
              case let .failure(error as IOSAssetStageFailure) = result,
              case .retained = error
        else {
            XCTFail("cancelled metadata dropped the leaf: \(String(describing: outcome.result))")
            return
        }
        harness.files.resumeMetadata()
        await waitUntil { harness.service.records[grant.workspaceID]?.consumerCount == 0 }
        XCTAssertEqual(harness.files.bytes(for: assetPath), bytes)
    }

    func testStageMetadataDeadlineKeepsScopeUntilDrainAfterInvalidate() async throws {
        let harness = AccessHarness(coordinationTimeoutNanoseconds: 300_000_000)
        let grant = try await harness.openDirectory()
        harness.files.mintedIdentity = { _ in nil }
        harness.files.parkMetadata = true
        let outcome = try await parkedStage(harness: harness, grant: grant, bytes: Data([5, 5, 5]))
        guard case .failure = outcome else {
            XCTFail("deadline published the asset")
            return
        }
        _ = harness.service.invalidate(grant.workspaceID)
        XCTAssertEqual(harness.scope.endCount, 0)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.consumerCount, 1)
        harness.files.resumeMetadata()
        await waitUntil { harness.scope.endCount == 1 }
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.consumerCount, 0)
        XCTAssertEqual(harness.files.bytes(for: assetPath), Data([5, 5, 5]))
    }

    func testRollbackDeadlineRetainsUntilTheRemoveDrains() async throws {
        try await assertRollback(cancel: false)
    }

    func testRollbackCancelRetainsUntilTheRemoveDrains() async throws {
        try await assertRollback(cancel: true)
    }

    func testReclaimDeadlineHoldsTheOperationUntilTheRemoveDrains() async throws {
        let harness = AccessHarness(coordinationTimeoutNanoseconds: 300_000_000)
        let grant = try await harness.openDirectory()
        harness.files.failMetadataAfterPersist = true
        harness.files.parkRemoves = true
        let bytes = Data([2, 2, 2])
        let outcome = StoredResult()
        let task = Task {
            do {
                _ = try await harness.service.stage(self.hero(grant: grant, bytes: bytes), grant: grant)
                outcome.store(.success(()))
            } catch {
                outcome.store(.failure(error))
            }
        }
        await waitUntil { harness.files.parkedRemoveCount == 1 }
        await waitUntil { outcome.result != nil }
        XCTAssertEqual(harness.files.bytes(for: assetPath), bytes)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 1)
        guard let result = outcome.result,
              case let .failure(error as IOSAssetStageFailure) = result,
              case .retained = error
        else {
            XCTFail("reclaim deadline treated a live leaf as a plain failure: \(String(describing: outcome.result))")
            return
        }
        _ = harness.service.invalidate(grant.workspaceID)
        XCTAssertEqual(harness.scope.endCount, 0)
        harness.files.resumeRemove()
        await waitUntil { harness.scope.endCount == 1 }
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 0)
        XCTAssertNil(harness.files.bytes(for: assetPath))
        _ = task
    }

    private func assertAdopt(cancel: Bool) async throws {
        let timeout: UInt64 = cancel ? 5_000_000_000 : 300_000_000
        let harness = AccessHarness(coordinationTimeoutNanoseconds: timeout)
        harness.files.rootIsDirectory = true
        harness.files.parkMetadata = true
        let url = IOSWorkspacePathAuthority.fileURL(path: "/tmp/plainsong-lane06/Adopt\(cancel)")
        let outcome = StoredResult()
        let task = Task {
            do {
                _ = try await harness.service.open(selectedURL: url, scope: .directory)
                outcome.store(.success(()))
            } catch {
                outcome.store(.failure(error))
            }
        }
        await waitUntil { harness.files.parkedMetadataCount == 1 }
        if cancel {
            task.cancel()
        }
        await waitUntil { outcome.result != nil }
        XCTAssertTrue(harness.service.records.isEmpty)
        XCTAssertEqual(harness.scope.endCount, 0)
        if cancel {
            XCTAssertTrue(outcome.result?.error is CancellationError)
        } else {
            XCTAssertEqual(outcome.result?.error as? IOSWorkspaceFailure, .coordinationFailed)
        }
        harness.files.resumeMetadata()
        await waitUntil { harness.scope.endCount == 1 }
        XCTAssertTrue(harness.service.records.isEmpty)
    }

    private func assertRollback(cancel: Bool) async throws {
        let timeout: UInt64 = cancel ? 5_000_000_000 : 300_000_000
        let harness = AccessHarness(coordinationTimeoutNanoseconds: timeout)
        let grant = try await harness.openDirectory()
        let bytes = Data([1, 2, 3])
        let staged = try await harness.service.stage(hero(grant: grant, bytes: bytes), grant: grant)
        harness.files.parkRemoves = true
        let outcome = RollbackBox()
        let task = Task {
            await outcome.store(harness.service.rollback(staged))
        }
        await waitUntil { harness.files.parkedRemoveCount == 1 }
        if cancel {
            task.cancel()
        }
        await waitUntil { outcome.value != nil }
        guard let value = outcome.value, case .retained = value else {
            XCTFail("rollback finished the delete before the port returned: \(String(describing: outcome.value))")
            return
        }
        let path = assetPath
        XCTAssertEqual(harness.files.bytes(for: path), bytes)
        harness.files.resumeRemove()
        await waitUntil { harness.files.bytes(for: path) == nil }
        XCTAssertNil(harness.files.bytes(for: path))
    }

    private func parkedStage(
        harness: AccessHarness,
        grant: IOSWorkspaceGrant,
        bytes: Data
    ) async throws -> Result<Void, Error> {
        let outcome = StoredResult()
        let task = Task {
            do {
                _ = try await harness.service.stage(self.hero(grant: grant, bytes: bytes), grant: grant)
                outcome.store(.success(()))
            } catch {
                outcome.store(.failure(error))
            }
        }
        await waitUntil { harness.files.parkedMetadataCount == 1 }
        await waitUntil { outcome.result != nil }
        _ = task
        return try XCTUnwrap(outcome.result)
    }

    private let assetPath = "notes/assets/hero.png"

    private func hero(grant: IOSWorkspaceGrant, bytes: Data) -> IOSImageAssetRequest {
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

private extension Result where Failure == Error {
    var error: Failure? {
        if case let .failure(error) = self {
            return error
        }
        return nil
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

private final class RollbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: IOSAssetRollbackOutcome?

    func store(_ value: IOSAssetRollbackOutcome) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: IOSAssetRollbackOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
