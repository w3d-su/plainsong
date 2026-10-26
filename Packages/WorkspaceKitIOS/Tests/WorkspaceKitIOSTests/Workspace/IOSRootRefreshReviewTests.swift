import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSRootRefreshReviewTests: XCTestCase {
    func testSupersededRootSuccessCannotPublishUnavailableAfterTheNewSnapshot() async throws {
        try await assertSupersededResult(.success([]))
    }

    func testSupersededRootFailureCannotPublishUnavailableAfterTheNewSnapshot() async throws {
        try await assertSupersededResult(.failure(IOSWorkspaceFailure.coordinationFailed))
    }

    func testSupersededOfflineListingCannotPublishUnavailableAfterTheNewSnapshot() async throws {
        try await assertSupersededResult(.failure(IOSWorkspaceFailure.offline))
    }

    func testLatestRootListingFailureStillPublishesUnavailable() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        let previous = try await harness.service.refresh(grant)
        var events: [IOSWorkspaceEvent] = []
        _ = harness.service.observe { events.append($0) }
        harness.files.listResult = .failure(IOSWorkspaceFailure.coordinationFailed)
        await harness.service.refreshRoot(grant)
        XCTAssertEqual(harness.service.snapshot(for: grant.workspaceID)?.requestID, previous.requestID)
        XCTAssertEqual(unavailableReasons(events), [.coordinationFailed])
        XCTAssertNotNil(harness.service.currentGrant(for: grant.workspaceID))
    }

    func testCancelledRootRefreshPublishesNoUnavailableAndDrainsItsOperation() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        var events: [IOSWorkspaceEvent] = []
        _ = harness.service.observe { events.append($0) }
        harness.files.parkLists = true
        let refresh = Task { await harness.service.refreshRoot(grant) }
        await waitUntil { harness.files.parkedListCount == 1 }
        refresh.cancel()
        await refresh.value
        XCTAssertTrue(unavailableReasons(events).isEmpty)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 1)
        harness.files.resumeList(.failure(IOSWorkspaceFailure.offline))
        await waitUntil { harness.service.records[grant.workspaceID]?.operationCount == 0 }
        XCTAssertTrue(unavailableReasons(events).isEmpty)
        XCTAssertNil(harness.service.snapshot(for: grant.workspaceID))
        XCTAssertNotNil(harness.service.currentGrant(for: grant.workspaceID))
    }

    func testRevokedRootRefreshCannotPublishASecondUnavailable() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        var events: [IOSWorkspaceEvent] = []
        _ = harness.service.observe { events.append($0) }
        harness.files.parkLists = true
        let refresh = Task { await harness.service.refreshRoot(grant) }
        await waitUntil { harness.files.parkedListCount == 1 }
        _ = harness.service.invalidate(grant.workspaceID)
        harness.files.resumeList(.failure(IOSWorkspaceFailure.offline))
        await refresh.value
        XCTAssertTrue(unavailableReasons(events).isEmpty)
        XCTAssertEqual(harness.scope.endCount, 1)
    }

    private func assertSupersededResult(_ result: Result<[IOSWorkspaceFileItem], Error>) async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        var events: [IOSWorkspaceEvent] = []
        _ = harness.service.observe { events.append($0) }
        harness.files.parkLists = true
        let older = Task { await harness.service.refreshRoot(grant) }
        await waitUntil { harness.files.parkedListCount == 1 }
        let newer = Task { await harness.service.refreshRoot(grant) }
        await waitUntil { harness.files.parkedListCount == 2 }
        harness.files.resumeList(.success([]), at: 1)
        await newer.value
        let current = try XCTUnwrap(harness.service.snapshot(for: grant.workspaceID))
        events.removeAll()
        harness.files.resumeList(result)
        await older.value
        XCTAssertEqual(harness.service.snapshot(for: grant.workspaceID)?.requestID, current.requestID)
        XCTAssertTrue(unavailableReasons(events).isEmpty)
        XCTAssertNotNil(harness.service.currentGrant(for: grant.workspaceID))
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.operationCount, 0)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.consumerCount, 0)
    }

    private func unavailableReasons(_ events: [IOSWorkspaceEvent]) -> [IOSWorkspaceFailure] {
        events.compactMap { event in
            if case let .unavailable(_, reason) = event {
                return reason
            }
            return nil
        }
    }
}
