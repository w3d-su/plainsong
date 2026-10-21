import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSWorkspaceLeaseRaceTests: XCTestCase {
    func testTwoConsumersEarlyReleaseDoesNotStopScope() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        let first = try harness.service.acquireLease(for: grant)
        let second = try harness.service.acquireLease(for: grant)
        first.release()
        first.release()
        XCTAssertEqual(harness.scope.endCount, 0)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.consumerCount, 1)
        second.release()
        XCTAssertEqual(harness.scope.endCount, 0)
        _ = harness.service.invalidate(grant.workspaceID)
        XCTAssertEqual(harness.scope.endCount, 1)
        XCTAssertNil(harness.service.currentGrant(for: grant.workspaceID))
    }

    func testCancelledReadHoldsScopeUntilTheOperationDrains() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        let lease = try harness.service.acquireLease(for: grant)
        harness.files.parkReads = true
        let location = harness.location(grant: grant, relativePath: "Note.md")
        let task = Task {
            try await harness.service.read(location, lease: lease, operationID: UUID(), maximumByteCount: 32)
        }
        await waitUntil { harness.files.parkedReadCount == 1 }
        XCTAssertEqual(harness.files.parkedReadCount, 1)
        lease.release()
        XCTAssertEqual(harness.scope.endCount, 0)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 1)
        _ = harness.service.invalidate(grant.workspaceID)
        XCTAssertEqual(harness.scope.endCount, 0)
        XCTAssertNotNil(harness.service.currentGrant(for: grant.workspaceID))
        harness.files.resumeRead(.failure(CancellationError()))
        do {
            _ = try await task.value
            XCTFail("cancelled read returned bytes")
        } catch is CancellationError {
            XCTAssertEqual(harness.scope.endCount, 1)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testLateReadAfterInvalidationDoesNotReturnBytes() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        let lease = try harness.service.acquireLease(for: grant)
        harness.files.parkReads = true
        let location = harness.location(grant: grant, relativePath: "Note.md")
        let task = Task {
            try await harness.service.read(location, lease: lease, operationID: UUID(), maximumByteCount: 32)
        }
        await waitUntil { harness.files.parkedReadCount == 1 }
        _ = harness.service.invalidate(grant.workspaceID)
        harness.files.resumeRead(.success(Data("late".utf8)))
        do {
            _ = try await task.value
            XCTFail("late read published bytes")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertEqual(failure, .grantChanged)
        }
    }

    func testRevokedGrantRejectsANewLeaseWhileDraining() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        let lease = try harness.service.acquireLease(for: grant)
        _ = harness.service.invalidate(grant.workspaceID)
        let live = try XCTUnwrap(harness.service.currentGrant(for: grant.workspaceID))
        XCTAssertThrowsError(try harness.service.acquireLease(for: live)) { error in
            XCTAssertEqual(error as? IOSWorkspaceFailure, .grantChanged)
        }
        XCTAssertEqual(harness.scope.endCount, 0)
        lease.release()
        XCTAssertEqual(harness.scope.endCount, 1)
    }
}
