import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSWorkspaceBookmarkTests: XCTestCase {
    func testFreshStaleDeniedAndOfflineBookmarks() async throws {
        let harness = AccessHarness()
        let url = IOSWorkspacePathAuthority.fileURL(path: "/tmp/plainsong-lane06/Folder")
        harness.files.rootIsDirectory = true
        harness.bookmarks.resolution = .resolved(url, isStale: false)
        let fresh = try await harness.service.restore(bookmark: Data("fresh".utf8), scope: .directory)
        XCTAssertEqual(fresh.scope, .directory)
        XCTAssertEqual(harness.recents.load().count, 1)

        let staleBookmark = Data("stale".utf8)
        harness.recents.save([
            IOSStoredRecentWorkspace(
                recordID: UUID(),
                displayName: "Folder",
                scope: .directory,
                openedAt: Date(timeIntervalSince1970: 10),
                providerIdentity: nil,
                status: .available,
                bookmark: staleBookmark
            ),
        ])
        harness.bookmarks.resolution = .resolved(url, isStale: true)
        _ = try await harness.service.restore(bookmark: staleBookmark, scope: .directory)
        XCTAssertEqual(harness.bookmarks.bookmarkCallCount, 1)
        XCTAssertTrue(harness.recents.load().contains { $0.bookmark == harness.bookmarks.refreshed })

        let deniedBookmark = Data("denied".utf8)
        harness.recents.save([
            IOSStoredRecentWorkspace(
                recordID: UUID(),
                displayName: "Folder",
                scope: .directory,
                openedAt: Date(timeIntervalSince1970: 10),
                providerIdentity: Data("id".utf8),
                status: .available,
                bookmark: deniedBookmark
            ),
        ])
        let deniedCount = harness.service.records.count
        harness.bookmarks.resolution = IOSBookmarkResolution(
            url: url,
            isStale: false,
            failure: .permissionDenied
        )
        do {
            _ = try await harness.service.restore(bookmark: deniedBookmark, scope: .directory)
            XCTFail("denied bookmark issued a grant")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertEqual(failure, .permissionDenied)
        }
        XCTAssertEqual(harness.service.records.count, deniedCount)
        XCTAssertEqual(harness.recents.load().first { $0.bookmark == deniedBookmark }?.status, .needsReselection)

        let offlineBookmark = Data("offline".utf8)
        harness.recents.save([
            IOSStoredRecentWorkspace(
                recordID: UUID(),
                displayName: "Folder",
                scope: .directory,
                openedAt: Date(timeIntervalSince1970: 10),
                providerIdentity: nil,
                status: .available,
                bookmark: offlineBookmark
            ),
        ])
        harness.bookmarks.resolution = IOSBookmarkResolution(url: url, isStale: false, failure: .offline)
        do {
            _ = try await harness.service.restore(bookmark: offlineBookmark, scope: .directory)
            XCTFail("offline bookmark issued a grant")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertEqual(failure, .offline)
        }
        XCTAssertEqual(harness.recents.load().first { $0.bookmark == offlineBookmark }?.status, .available)
    }

    func testRecentsKeepTenSuccessesAndDoNotDeleteFiles() async throws {
        let harness = AccessHarness()
        harness.files.rootIsDirectory = false
        for index in 0 ..< 11 {
            harness.identity.identity = Data([UInt8(index)])
            _ = try await harness.service.open(
                selectedURL: IOSWorkspacePathAuthority.fileURL(path: "/tmp/plainsong-lane06/file-\(index).md"),
                scope: .singleFile
            )
        }
        let identified = harness.recents.load()
        XCTAssertEqual(identified.count, 10)
        XCTAssertFalse(identified.contains { $0.providerIdentity == Data([0]) })
        XCTAssertTrue(identified.contains { $0.providerIdentity == Data([10]) })

        harness.identity.identity = nil
        _ = try await harness.service.open(
            selectedURL: IOSWorkspacePathAuthority.fileURL(path: "/tmp/plainsong-lane06/one.md"),
            scope: .singleFile
        )
        _ = try await harness.service.open(
            selectedURL: IOSWorkspacePathAuthority.fileURL(path: "/tmp/plainsong-lane06/two.md"),
            scope: .singleFile
        )
        let unknown = harness.service.recentItems().filter { $0.providerIdentity == nil }
        XCTAssertEqual(unknown.count, 2)
        let removed = try XCTUnwrap(unknown.first?.recordID)
        let calls = harness.files.ioCalls
        harness.service.removeRecent(recordID: removed)
        XCTAssertEqual(harness.files.ioCalls, calls)
        XCTAssertFalse(harness.service.recentItems().contains { $0.recordID == removed })
    }

    func testSingleFileGrantDoesNotReadASibling() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openFile()
        let parent = grant.rootURL.deletingLastPathComponent()
        let sibling = IOSFileLocation(
            workspaceID: grant.workspaceID,
            accessGeneration: grant.accessGeneration,
            relativePath: "Other.md",
            fileURL: IOSWorkspacePathAuthority.fileURL(
                path: IOSWorkspacePathAuthority.joined(root: parent, relativePath: "Other.md")
            ),
            resourceID: nil
        )
        let readsBefore = harness.files.readCalls
        do {
            _ = try await harness.service.read(
                sibling,
                lease: harness.service.acquireLease(for: grant),
                operationID: UUID(),
                maximumByteCount: 16
            )
            XCTFail("sibling read succeeded")
        } catch let failure as IOSWorkspaceFailure {
            XCTAssertEqual(failure, .outsideGrant)
        }
        XCTAssertEqual(harness.files.readCalls, readsBefore)
        XCTAssertEqual(
            harness.scope.beganURLs.first?.path(percentEncoded: false),
            "/tmp/plainsong-lane06/Folder/Note.md"
        )
        let snapshot = try await harness.service.refresh(grant)
        XCTAssertEqual(snapshot.entries.count, 1)
    }
}
