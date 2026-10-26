import Foundation
@testable import PlainsongIOS
import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSGrantAdoptionTests: XCTestCase {
    func testRetiringOldGrantCannotAdoptDestinationRevokedByItsInvalidationObserver() async throws {
        let fixture = try await directoryFixture()
        let old = try XCTUnwrap(fixture.controller.currentGrant)
        let destination = try await fixture.workspace.open(selectedURL: destinationURL, scope: .directory)
        let tree = try await fixture.workspace.refresh(destination)
        let observation = fixture.workspace.observe { event in
            guard case let .invalidated(identity, _) = event, identity == old.workspaceID else { return }
            _ = fixture.workspace.invalidate(destination.workspaceID)
        }
        defer { observation.cancel() }
        try fixture.controller.beginTransition()
        defer { fixture.controller.finishTransition() }

        do {
            try fixture.controller.adoptCurrentGrant(destination, snapshot: tree)
            XCTFail("Old-scope callbacks revoked the destination before its adoption proof")
        } catch {
            XCTAssertEqual(error as? IOSWorkspaceFailure, .grantChanged)
        }
        XCTAssertNil(fixture.controller.currentGrant)
        XCTAssertFalse(fixture.controller.grantIsCurrent)
        XCTAssertNil(fixture.controller.workspaceSnapshot)
        XCTAssertTrue(fixture.store.opened.isEmpty, "A directory replacement must not open a writer")
        XCTAssertTrue(fixture.workspace.invalidated.contains(old.workspaceID))
        XCTAssertTrue(fixture.workspace.invalidated.contains(destination.workspaceID))
    }

    func testProofReleaseRevocationObservesAdoptedGrantAndPreservesUnavailableReason() async throws {
        let fixture = try await directoryFixture()
        let destination = try await fixture.workspace.open(selectedURL: destinationURL, scope: .directory)
        let tree = try await fixture.workspace.refresh(destination)
        var releaseObservedAdoptedGrant = false
        fixture.workspace.onLeaseRelease = { grant in
            guard grant.workspaceID == destination.workspaceID else { return }
            releaseObservedAdoptedGrant = fixture.controller.currentGrant?.workspaceID == destination.workspaceID
            _ = fixture.workspace.invalidate(destination.workspaceID)
        }
        try fixture.controller.beginTransition()
        defer { fixture.controller.finishTransition() }

        try fixture.controller.adoptCurrentGrant(destination, snapshot: tree)

        XCTAssertTrue(releaseObservedAdoptedGrant, "Proof release must occur after atomic grant adoption")
        XCTAssertEqual(fixture.controller.currentGrant?.workspaceID, destination.workspaceID)
        XCTAssertFalse(fixture.controller.grantIsCurrent)
        XCTAssertNil(fixture.controller.workspaceSnapshot)
        XCTAssertEqual(fixture.controller.snapshot.unavailableReason,
                       "File access changed. Select the file or folder again.")
        XCTAssertTrue(fixture.store.opened.isEmpty)
        XCTAssertTrue(fixture.workspace.leases.allSatisfy(\.isReleased))
    }

    private let destinationURL = URL(fileURLWithPath: "/synthetic/recovered", isDirectory: true)

    private func directoryFixture() async throws -> IOSSceneControllerFixture {
        let fixture = IOSSceneControllerFixture()
        try await fixture.controller.openPickedURL(
            URL(fileURLWithPath: "/synthetic/original", isDirectory: true), scope: .directory
        )
        XCTAssertNil(fixture.controller.handle)
        return fixture
    }
}
