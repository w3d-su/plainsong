import Foundation
import MarkdownCore
import PreviewKitContracts
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSWorkspaceRevocationTests: XCTestCase {
    func testRevokedDrainingRecordIssuesNoPreviewContext() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        let lease = try harness.service.acquireLease(for: grant)
        _ = harness.service.invalidate(grant.workspaceID)
        // The held lease keeps the record draining, so it still reports a grant.
        let draining = try XCTUnwrap(harness.service.currentGrant(for: grant.workspaceID))
        XCTAssertEqual(harness.scope.endCount, 0)
        XCTAssertNil(harness.service.previewContext(for: draining))
        let forged = try PreviewAssetAccessContext(
            allowedRoot: draining.rootURL,
            rootToken: XCTUnwrap(harness.service.records[grant.workspaceID]).rootToken,
            grantIdentity: draining.workspaceID.rawValue,
            accessGeneration: draining.accessGeneration
        )
        XCTAssertFalse(harness.service.isCurrent(forged))
        lease.release()
        XCTAssertEqual(harness.scope.endCount, 1)
    }

    func testCancelledWorkspaceObservationIsRemoved() async throws {
        let harness = AccessHarness()
        let baseline = harness.service.observations.count
        var received = 0
        let observation = harness.service.observe { _ in received += 1 }
        XCTAssertEqual(harness.service.observations.count, baseline + 1)
        observation.cancel()
        observation.cancel()
        XCTAssertEqual(harness.service.observations.count, baseline)
        let grant = try await harness.openDirectory()
        _ = harness.service.invalidate(grant.workspaceID)
        XCTAssertEqual(received, 0)
    }

    func testCancelledDocumentObservationIsRemoved() {
        let harness = DocumentIOHarness()
        let baseline = harness.store.observations.count
        let observation = harness.store.observe { _ in }
        XCTAssertEqual(harness.store.observations.count, baseline + 1)
        observation.cancel()
        XCTAssertEqual(harness.store.observations.count, baseline)
    }
}
