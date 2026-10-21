import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSWorkspaceAssetRecoveryTests: XCTestCase {
    func testSameSizeReplacementWithANewIdentityIsRetained() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        let staged = try await harness.service.stage(
            request(name: "hero.png", bytes: Data([1, 2, 3]), grant: grant),
            grant: grant
        )
        let path = staged.targetLocation.relativePath
        harness.files.replaceBytes(Data([9, 9, 9]), relativePath: path, identity: Data("other-writer".utf8))
        let outcome = await harness.service.rollback(staged)
        guard case let .retained(receipt) = outcome else {
            XCTFail("same-size replacement was deleted: \(outcome)")
            return
        }
        XCTAssertEqual(receipt.reason, .indeterminate)
        XCTAssertEqual(harness.files.bytes(for: path), Data([9, 9, 9]))
        XCTAssertTrue(harness.files.removedPaths().isEmpty)
    }

    func testMetadataSnapshotDoesNotAuthorizeDeletingAReplacement() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        harness.files.swapIdentityAfterMetadata = Data("replaced-after-metadata".utf8)
        let staged = try await harness.service.stage(
            request(name: "hero.png", bytes: Data([1, 2, 3]), grant: grant),
            grant: grant
        )
        let path = staged.targetLocation.relativePath
        let replacement = try XCTUnwrap(harness.files.bytes(for: path))
        XCTAssertEqual(replacement.count, 3)
        XCTAssertNotEqual(replacement, Data([1, 2, 3]))
        let before = harness.files.metadataCalls
        let outcome = await harness.service.rollback(staged)
        guard case .retained = outcome else {
            XCTFail("post-metadata replacement was deleted: \(outcome)")
            return
        }
        XCTAssertEqual(harness.files.metadataCalls, before)
        XCTAssertEqual(harness.files.bytes(for: path), replacement)
        XCTAssertTrue(harness.files.removedPaths().isEmpty)
    }

    func testNilIdentityRollbackRetainsTheLeaf() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        harness.files.mintedIdentity = { _ in nil }
        let staged = try await harness.service.stage(
            request(name: "hero.png", bytes: Data([4, 4, 4]), grant: grant),
            grant: grant
        )
        let path = staged.targetLocation.relativePath
        harness.files.replaceBytes(Data([5, 5, 5]), relativePath: path, identity: Data("same-size".utf8))
        let outcome = await harness.service.rollback(staged)
        guard case .retained = outcome else {
            XCTFail("unproven leaf was deleted: \(outcome)")
            return
        }
        XCTAssertEqual(harness.files.bytes(for: path), Data([5, 5, 5]))
        XCTAssertTrue(harness.files.removedPaths().isEmpty)
    }

    func testRollbackLeavesAnotherOperationsLeaf() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        let hero = try await harness.service.stage(
            request(name: "hero.png", bytes: Data([1, 1, 1]), grant: grant),
            grant: grant
        )
        let side = try await harness.service.stage(
            request(name: "side.png", bytes: Data([1, 1, 1]), grant: grant),
            grant: grant
        )
        let removed = await harness.service.rollback(hero)
        guard case .removed = removed else {
            XCTFail("owned leaf was kept: \(removed)")
            return
        }
        XCTAssertNil(harness.files.bytes(for: hero.targetLocation.relativePath))
        XCTAssertEqual(harness.files.bytes(for: side.targetLocation.relativePath), Data([1, 1, 1]))
    }

    func testInvalidateBetweenPersistAndAcceptKeepsAReceipt() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        harness.files.mintedIdentity = { _ in nil }
        harness.files.parkAfterPersist = true
        let task = Task {
            try await harness.service.stage(
                request(name: "hero.png", bytes: Data([7, 7, 7]), grant: grant),
                grant: grant
            )
        }
        await waitUntil { harness.files.parkedCreateCount == 1 }
        XCTAssertEqual(harness.files.parkedCreateCount, 1)
        XCTAssertEqual(harness.files.bytes(for: "notes/assets/hero.png"), Data([7, 7, 7]))
        _ = harness.service.invalidate(grant.workspaceID)
        harness.files.resumeCreate()
        do {
            _ = try await task.value
            XCTFail("invalidated stage published the leaf")
        } catch let failure as IOSAssetStageFailure {
            assertReceiptOrAbsence(failure, harness: harness, path: "notes/assets/hero.png")
            guard case .retained = failure else {
                XCTFail("unproven persisted leaf had no receipt: \(failure)")
                return
            }
            XCTAssertEqual(harness.files.bytes(for: "notes/assets/hero.png"), Data([7, 7, 7]))
        }
    }

    func testMetadataFailureAfterPersistDoesNotLeaveAnUnreceiptedLeaf() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        harness.files.mintedIdentity = { _ in nil }
        harness.files.failMetadataAfterPersist = true
        do {
            _ = try await harness.service.stage(
                request(name: "hero.png", bytes: Data([8, 8, 8]), grant: grant),
                grant: grant
            )
            XCTFail("unreadable persisted leaf was published")
        } catch let failure as IOSAssetStageFailure {
            assertReceiptOrAbsence(failure, harness: harness, path: "notes/assets/hero.png")
            guard case .retained = failure else {
                XCTFail("nil identity was deleted or dropped: \(failure)")
                return
            }
            XCTAssertEqual(harness.files.bytes(for: "notes/assets/hero.png"), Data([8, 8, 8]))
        }
    }

    func testProvedIdentityIsRemovedWhenPublishFails() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        harness.files.failMetadataAfterPersist = true
        do {
            _ = try await harness.service.stage(
                request(name: "hero.png", bytes: Data([2, 2, 2]), grant: grant),
                grant: grant
            )
            XCTFail("failed publish returned an asset")
        } catch let failure as IOSAssetStageFailure {
            assertReceiptOrAbsence(failure, harness: harness, path: "notes/assets/hero.png")
            guard case let .failed(reason) = failure else {
                XCTFail("proved leaf was retained: \(failure)")
                return
            }
            XCTAssertEqual(reason, .coordinationFailed)
            XCTAssertNil(harness.files.bytes(for: "notes/assets/hero.png"))
        }
    }

    private func request(name: String, bytes: Data, grant: IOSWorkspaceGrant) -> IOSImageAssetRequest {
        IOSImageAssetRequest(
            operationID: UUID(),
            bytes: bytes,
            contentType: "image/png",
            preferredFilename: name,
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

    private func assertReceiptOrAbsence(
        _ failure: IOSAssetStageFailure,
        harness: AccessHarness,
        path: String
    ) {
        if harness.files.bytes(for: path) != nil {
            guard case .retained = failure else {
                XCTFail("leaf \(path) remains without a receipt: \(failure)")
                return
            }
        }
    }
}
