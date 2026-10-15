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
            try await Task.sleep(nanoseconds: 100_000_000)
        } else {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertNil(outcome.result, "caller finished before the parked write settled")
        if unreadable {
            harness.files.resumeCreateUnreadable()
        } else {
            harness.files.resumeCreate()
        }
        await waitUntil { outcome.result != nil }
        let result = try XCTUnwrap(outcome.result)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 0)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.consumerCount, 0)
        if let remaining {
            guard case let .failure(error) = result,
                  let failure = error as? IOSAssetStageFailure,
                  case .retained = failure
            else {
                XCTFail("persisted leaf had no receipt: \(result)")
                return
            }
            XCTAssertFalse(result.error is CancellationError)
            XCTAssertEqual(harness.files.bytes(for: assetPath), remaining)
        } else {
            XCTAssertNil(harness.files.bytes(for: assetPath))
            guard case let .failure(error) = result else {
                XCTFail("removed leaf was published")
                return
            }
            if cancel {
                XCTAssertTrue(error is CancellationError, "\(error)")
            } else if let failure = error as? IOSAssetStageFailure, case let .failed(reason) = failure {
                XCTAssertEqual(reason, .coordinationFailed)
            } else {
                XCTFail("removed leaf was retained: \(error)")
            }
        }
        _ = task
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
