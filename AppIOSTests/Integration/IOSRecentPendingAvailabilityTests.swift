import Foundation
import MarkdownCore
@testable import PlainsongIOS
import WorkspaceCore
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSRecentPendingAvailabilityTests: XCTestCase {
    func testDownloadingRecentRetainsItsGrantForRefreshAndRetry() async throws {
        try await assertPendingRecentCanRetry(availability: .downloading, failure: .downloading)
    }

    func testOfflineRecentRetainsItsGrantForRefreshAndRetry() async throws {
        try await assertPendingRecentCanRetry(availability: .offline, failure: .offline)
    }

    func testPendingRecentStillRejectsAnUnselectedSibling() async throws {
        let fixture = try await pendingRecent(availability: .downloading, failure: .downloading)
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        do {
            try await fixture.controller.openSelectedURL(
                grant.rootURL.deletingLastPathComponent().appendingPathComponent("unselected.md"), scope: .singleFile
            )
            XCTFail("A restored single-file grant cannot authorize a sibling")
        } catch {
            XCTAssertEqual(error as? IOSDocumentFailure, .access(.outsideGrant))
        }
        XCTAssertEqual(fixture.controller.currentGrant?.workspaceID, grant.workspaceID)
        XCTAssertTrue(fixture.controller.grantIsCurrent)
        XCTAssertTrue(fixture.store.opened.isEmpty)
        XCTAssertTrue(fixture.access.workspace.base.selected.isEmpty)
    }

    func testPendingRecentDoesNotSurviveActualRevocation() async throws {
        let fixture = try await pendingRecent(availability: .offline, failure: .offline)
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        _ = fixture.access.workspace.invalidate(grant.workspaceID)
        fixture.access.workspace.base.singleFileAvailability = .available(canWrite: true)
        do {
            try await fixture.controller.refreshWorkspace()
            XCTFail("Availability recovery cannot revive a revoked grant")
        } catch {
            XCTAssertEqual(error as? IOSWorkspaceFailure, .unavailable)
        }
        XCTAssertFalse(fixture.controller.grantIsCurrent)
        XCTAssertNil(fixture.controller.snapshot.workspace)
        XCTAssertTrue(fixture.store.opened.isEmpty)
        XCTAssertTrue(fixture.access.workspace.base.leases.allSatisfy(\.isReleased))
    }

    func testAnUnsupportedRecentStillRetiresItsNewGrant() async throws {
        let fixture = IOSRecentSceneFixture()
        let id = fixture.access.add(scope: .singleFile)
        fixture.access.workspace.base.singleFileKind = .image
        fixture.access.workspace.base.singleFileAvailability = .downloading
        do {
            try await fixture.controller.openRecent(recordID: id, using: fixture.access)
            XCTFail("Cloud availability cannot make an image a document")
        } catch {
            XCTAssertEqual(error as? IOSDocumentFailure, .access(.unsupportedType))
        }
        let grant = try XCTUnwrap(fixture.access.restoredGrant)
        XCTAssertTrue(fixture.access.workspace.base.invalidated.contains(grant.workspaceID))
        XCTAssertNil(fixture.controller.currentGrant)
        XCTAssertNil(fixture.controller.snapshot.workspace)
        XCTAssertTrue(fixture.store.opened.isEmpty)
    }

    func testDownloadingFailureAfterRecentSnapshotRetainsGrantForRetry() async throws {
        try await assertProviderFailureCanRetry(.downloading)
    }

    func testOfflineFailureAfterRecentSnapshotRetainsGrantForRetry() async throws {
        try await assertProviderFailureCanRetry(.offline)
    }

    func testCancelledProviderFailureDoesNotRetainAnAbandonedRecentGrant() async throws {
        let fixture = IOSRecentSceneFixture()
        let id = fixture.access.add(scope: .singleFile)
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.store.openLatch = latch
        fixture.store.openFailure = .access(.offline)
        let started = expectation(description: "Recent provider open is parked")
        fixture.store.onOpen = { started.fulfill() }
        let recent = Task { try await fixture.controller.openRecent(recordID: id, using: fixture.access) }
        await fulfillment(of: [started], timeout: 2)
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        recent.cancel()
        latch.release()
        do {
            try await recent.value
            XCTFail("A cancelled failed open cannot complete")
        } catch {
            XCTAssertEqual(error as? IOSDocumentFailure, .access(.offline))
        }
        XCTAssertTrue(fixture.access.workspace.base.invalidated.contains(grant.workspaceID))
        XCTAssertTrue(fixture.access.workspace.base.leases.allSatisfy(\.isReleased))
        XCTAssertNil(fixture.controller.currentGrant)
        XCTAssertNil(fixture.controller.snapshot.workspace)
        XCTAssertNil(fixture.controller.handle)
        XCTAssertNil(fixture.controller.admission.active)
    }

    func testRevokedProviderFailureDoesNotRetainAnUnauthorizedRecentGrant() async throws {
        let fixture = IOSRecentSceneFixture()
        let id = fixture.access.add(scope: .singleFile)
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.store.openLatch = latch
        fixture.store.openFailure = .access(.downloading)
        let started = expectation(description: "Recent provider open is parked before revocation")
        fixture.store.onOpen = { started.fulfill() }
        let recent = Task { try await fixture.controller.openRecent(recordID: id, using: fixture.access) }
        await fulfillment(of: [started], timeout: 2)
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        _ = fixture.access.workspace.invalidate(grant.workspaceID)
        latch.release()
        do {
            try await recent.value
            XCTFail("A revoked failed open cannot complete")
        } catch {
            XCTAssertEqual(error as? IOSDocumentFailure, .access(.downloading))
        }
        XCTAssertTrue(fixture.access.workspace.base.leases.allSatisfy(\.isReleased))
        XCTAssertFalse(fixture.controller.grantIsCurrent)
        XCTAssertNil(fixture.controller.currentGrant)
        XCTAssertNil(fixture.controller.snapshot.workspace)
        XCTAssertNil(fixture.controller.handle)
        XCTAssertNil(fixture.controller.admission.active)
    }

    func testSupersedingURLWaitsForProviderFailureAndRetiresTheAbandonedRecentGrant() async throws {
        let fixture = IOSRecentSceneFixture()
        let id = fixture.access.add(scope: .singleFile)
        let latch = IOSSceneControllerLatch()
        defer { latch.release() }
        fixture.store.openLatch = latch
        fixture.store.openFailure = .access(.offline)
        let started = expectation(description: "Recent provider open is parked before supersession")
        fixture.store.onOpen = { started.fulfill() }
        let recent = Task { try await fixture.controller.openRecent(recordID: id, using: fixture.access) }
        await fulfillment(of: [started], timeout: 2)
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        var abandonedGrantWasPublished = false
        let observation = fixture.controller.observe { _ in
            if !fixture.controller.transitioning, fixture.controller.currentGrant?.workspaceID == grant.workspaceID {
                abandonedGrantWasPublished = true
            }
        }
        defer { observation.cancel() }
        let target = URL(fileURLWithPath: "/synthetic/after-provider-failure.md")
        let picked = Task { try await fixture.controller.openPickedURL(target, scope: .singleFile) }
        try await waitUntil { fixture.controller.pendingRecentNavigation != nil }
        XCTAssertTrue(fixture.access.workspace.base.selected.isEmpty)
        XCTAssertEqual(fixture.store.opened.count, 1)
        fixture.store.openFailure = nil
        fixture.store.onOpen = nil
        latch.release()
        do {
            try await recent.value
            XCTFail("A superseded failed open cannot complete")
        } catch {
            XCTAssertEqual(error as? IOSDocumentFailure, .access(.offline))
        }
        try await picked.value
        XCTAssertFalse(abandonedGrantWasPublished)
        XCTAssertTrue(fixture.access.workspace.base.invalidated.contains(grant.workspaceID))
        XCTAssertNotEqual(fixture.controller.currentGrant?.workspaceID, grant.workspaceID)
        XCTAssertEqual(fixture.access.workspace.base.selected.map(\.0), [target])
        XCTAssertEqual(fixture.controller.handle?.location.fileURL, target)
        XCTAssertEqual(fixture.store.opened.count, 2)
        XCTAssertTrue(fixture.editor.snapshot.canWrite)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("The superseding navigation did not reach the expected suspension")
        throw IOSDocumentFailure.unavailable
    }

    private func assertProviderFailureCanRetry(_ failure: IOSWorkspaceFailure) async throws {
        let fixture = IOSRecentSceneFixture()
        let id = fixture.access.add(scope: .singleFile)
        fixture.store.openFailure = .access(failure)
        do {
            try await fixture.controller.openRecent(recordID: id, using: fixture.access)
            XCTFail("A provider failure after snapshot cannot open a writer")
        } catch {
            XCTAssertEqual(error as? IOSDocumentFailure, .access(failure))
        }
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        XCTAssertTrue(fixture.controller.grantIsCurrent)
        XCTAssertNotNil(fixture.controller.snapshot.workspace)
        XCTAssertTrue(fixture.access.workspace.base.invalidated.isEmpty)
        XCTAssertTrue(fixture.access.workspace.base.leases.allSatisfy(\.isReleased))
        XCTAssertNil(fixture.controller.handle)
        XCTAssertNil(fixture.controller.admission.active)
        fixture.store.openFailure = nil
        try await fixture.controller.refreshWorkspace()
        try await fixture.controller.openSelectedURL(grant.rootURL, scope: .singleFile)
        XCTAssertEqual(fixture.controller.currentGrant?.workspaceID, grant.workspaceID)
        XCTAssertEqual(fixture.access.restoreCalls, [id])
        XCTAssertTrue(fixture.access.workspace.base.selected.isEmpty)
        XCTAssertEqual(fixture.store.opened.count, 2)
        XCTAssertTrue(fixture.editor.snapshot.canWrite)
    }

    private func assertPendingRecentCanRetry(
        availability: IOSFileAvailability, failure: IOSWorkspaceFailure
    ) async throws {
        let fixture = try await pendingRecent(availability: availability, failure: failure)
        let grant = try XCTUnwrap(fixture.controller.currentGrant)
        let restoreCalls = fixture.access.restoreCalls
        fixture.access.workspace.base.singleFileAvailability = .available(canWrite: true)
        try await fixture.controller.refreshWorkspace()
        try await fixture.controller.openSelectedURL(grant.rootURL, scope: .singleFile)
        XCTAssertEqual(fixture.controller.currentGrant?.workspaceID, grant.workspaceID)
        XCTAssertEqual(fixture.access.restoreCalls, restoreCalls)
        XCTAssertTrue(fixture.access.workspace.base.selected.isEmpty)
        XCTAssertTrue(fixture.access.workspace.base.invalidated.isEmpty)
        XCTAssertEqual(fixture.store.opened.count, 1)
        XCTAssertEqual(fixture.controller.handle?.location.fileURL, grant.rootURL)
        XCTAssertTrue(fixture.editor.snapshot.canWrite)
        XCTAssertFalse(fixture.controller.transitioning)
    }

    private func pendingRecent(
        availability: IOSFileAvailability, failure: IOSWorkspaceFailure
    ) async throws -> IOSRecentSceneFixture {
        let fixture = IOSRecentSceneFixture()
        let id = fixture.access.add(scope: .singleFile)
        fixture.access.workspace.base.singleFileAvailability = availability
        do {
            try await fixture.controller.openRecent(recordID: id, using: fixture.access)
            XCTFail("The document must wait for its provider")
        } catch {
            XCTAssertEqual(error as? IOSDocumentFailure, .access(failure))
        }
        XCTAssertNotNil(fixture.controller.currentGrant)
        XCTAssertTrue(fixture.controller.grantIsCurrent)
        XCTAssertEqual(fixture.controller.snapshot.workspace?.entries.first?.availability, availability)
        XCTAssertTrue(fixture.access.workspace.base.invalidated.isEmpty)
        XCTAssertTrue(fixture.access.workspace.base.leases.allSatisfy(\.isReleased))
        XCTAssertTrue(fixture.store.opened.isEmpty)
        XCTAssertNil(fixture.controller.handle)
        XCTAssertNil(fixture.controller.admission.active)
        XCTAssertFalse(fixture.controller.transitioning)
        return fixture
    }
}
