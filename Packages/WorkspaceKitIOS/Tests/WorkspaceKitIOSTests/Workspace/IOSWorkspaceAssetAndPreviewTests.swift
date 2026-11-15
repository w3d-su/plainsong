import Foundation
import PreviewKitContracts
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSWorkspaceAssetAndPreviewTests: XCTestCase {
    func testSingleFileGrantDoesNotStageIntoParent() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openFile()
        let request = IOSImageAssetRequest(
            operationID: UUID(),
            bytes: Data([1, 2, 3]),
            contentType: "image/png",
            preferredFilename: "hero.png",
            destination: harness.location(grant: grant, relativePath: "Note.md")
        )
        do {
            _ = try await harness.service.stage(request, grant: grant)
            XCTFail("single-file grant staged an image")
        } catch let failure as IOSAssetStageFailure {
            guard case let .failed(reason) = failure else {
                XCTFail("unexpected \(failure)")
                return
            }
            XCTAssertEqual(reason, .requiresDirectoryGrant)
        }
        XCTAssertEqual(harness.files.createCalls, 0)
    }

    func testRollbackRemovesOnlyTheFailedOperation() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        let document = harness.location(grant: grant, relativePath: "notes/post.md")
        let first = try await harness.service.stage(
            imageRequest(operation: 1, name: "hero.png", document: document),
            grant: grant
        )
        let second = try await harness.service.stage(
            imageRequest(operation: 2, name: "side.png", document: document),
            grant: grant
        )
        let removed = await harness.service.rollback(first)
        guard case .removed = removed else {
            XCTFail("expected removal, got \(removed)")
            return
        }
        XCTAssertEqual(harness.files.removedPaths(), ["hero.png"])
        XCTAssertTrue(harness.files.contains(second.targetLocation.relativePath))
        let committed = await harness.service.commit(second)
        guard case .committed = committed else {
            XCTFail("expected commit")
            return
        }
        let retained = await harness.service.rollback(second)
        guard case let .retained(receipt) = retained else {
            XCTFail("committed rollback deleted the leaf")
            return
        }
        XCTAssertEqual(receipt.reason, .indeterminate)
        XCTAssertEqual(harness.files.removedPaths(), ["hero.png"])
    }

    func testPreviewReaderHoldsTheLeaseUntilTheReadFinishes() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        let access = try XCTUnwrap(harness.service.previewContext(for: grant))
        let url = IOSWorkspacePathAuthority.fileURL(
            path: IOSWorkspacePathAuthority.joined(root: grant.rootURL, relativePath: "assets/plain.txt")
        )
        harness.files.parkReads = true
        let task = Task {
            try await harness.service.read(
                PreviewAssetReadRequest(requestID: UUID(), resolvedURL: url, access: access, maximumByteCount: 32)
            )
        }
        await waitUntil { harness.files.parkedReadCount == 1 }
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.consumerCount, 1)
        XCTAssertEqual(harness.scope.endCount, 0)
        harness.files.resumeRead(.success(Data("txt".utf8)))
        let result = try await task.value
        XCTAssertEqual(result.bytes, Data("txt".utf8))
        XCTAssertEqual(result.access.grantIdentity, access.grantIdentity)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.consumerCount, 0)
        _ = harness.service.invalidate(grant.workspaceID)
        XCTAssertFalse(harness.service.isCurrent(access))
    }

    /// The document picker's folder URL ends in a slash. Every relative image
    /// in a picked folder was refused as outside the root.
    func testPreviewReaderReadsBelowAPickedFolderURLWithATrailingSlash() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory("/tmp/plainsong-lane06/Folder/")
        XCTAssertTrue(grant.rootURL.path(percentEncoded: false).hasSuffix("/"))
        let access = try XCTUnwrap(harness.service.previewContext(for: grant))
        let url = IOSWorkspacePathAuthority.fileURL(path: "/tmp/plainsong-lane06/Folder/assets/plain.txt")
        harness.files.parkReads = true
        let task = Task {
            try await harness.service.read(
                PreviewAssetReadRequest(requestID: UUID(), resolvedURL: url, access: access, maximumByteCount: 32)
            )
        }
        await waitUntil { harness.files.parkedReadCount == 1 }
        harness.files.resumeRead(.success(Data("txt".utf8)))
        let result = try await task.value
        XCTAssertEqual(result.bytes, Data("txt".utf8))
    }

    func testRelativeSpellingTreatsATrailingSlashRootAsTheSameDirectory() {
        let file = IOSWorkspacePathAuthority.fileURL(path: "/tmp/Folder/assets/a.png")
        for root in ["/tmp/Folder", "/tmp/Folder/"] {
            let rootURL = IOSWorkspacePathAuthority.fileURL(path: root)
            XCTAssertEqual(IOSWorkspacePathAuthority.relativeSpelling(root: rootURL, file: file), "assets/a.png")
            let sibling = IOSWorkspacePathAuthority.fileURL(path: "/tmp/Folder2/a.png")
            XCTAssertNil(IOSWorkspacePathAuthority.relativeSpelling(root: rootURL, file: sibling))
            XCTAssertNil(IOSWorkspacePathAuthority.relativeSpelling(root: rootURL, file: rootURL))
            let escape = IOSWorkspacePathAuthority.fileURL(path: "/tmp/Folder/../secret.png")
            XCTAssertNil(IOSWorkspacePathAuthority.relativeSpelling(root: rootURL, file: escape))
        }
    }

    func testSingleFilePreviewDoesNotReadASibling() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openFile()
        let access = try XCTUnwrap(harness.service.previewContext(for: grant))
        let parent = grant.rootURL.deletingLastPathComponent()
        let sibling = IOSWorkspacePathAuthority.fileURL(
            path: IOSWorkspacePathAuthority.joined(root: parent, relativePath: "other.png")
        )
        do {
            _ = try await harness.service.read(
                PreviewAssetReadRequest(requestID: UUID(), resolvedURL: sibling, access: access, maximumByteCount: 32)
            )
            XCTFail("sibling preview read succeeded")
        } catch let failure as PreviewAssetReadFailure {
            XCTAssertEqual(failure, .outsideRoot)
        }
        XCTAssertEqual(harness.files.readCalls, 0)
    }

    private func imageRequest(operation: UInt8, name: String, document: IOSFileLocation) -> IOSImageAssetRequest {
        IOSImageAssetRequest(
            operationID: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(operation)") ?? UUID(),
            bytes: Data([operation, 9, 9]),
            contentType: "image/png",
            preferredFilename: name,
            destination: document
        )
    }
}
