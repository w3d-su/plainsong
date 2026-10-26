import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSBookmarkRetryReviewTests: XCTestCase {
    func testTransientMetadataFailuresLeaveFreshAndStaleBookmarksRetryable() async throws {
        for isStale in [false, true] {
            for failure in [IOSWorkspaceFailure.offline, .coordinationFailed, .unavailable, .downloading] {
                let harness = AccessHarness()
                let bookmark = seed(harness, isStale: isStale)
                harness.files.metadataFailure = failure
                do {
                    _ = try await harness.service.restore(bookmark: bookmark, scope: .directory)
                    XCTFail("transient metadata failure issued a grant")
                } catch {
                    XCTAssertEqual(error as? IOSWorkspaceFailure, failure)
                }
                assertRetryable(harness, bookmark: bookmark)
                XCTAssertEqual(harness.scope.endCount, 1)
                harness.files.metadataFailure = nil
                let grant = try await harness.service.restore(bookmark: bookmark, scope: .directory)
                XCTAssertEqual(harness.bookmarks.bookmarkCallCount, isStale ? 1 : 0)
                XCTAssertEqual(harness.service.records[grant.workspaceID]?.bookmark,
                               isStale ? harness.bookmarks.refreshed : bookmark)
                _ = harness.service.invalidate(grant.workspaceID)
                XCTAssertEqual(harness.scope.endCount, 2)
            }
        }
    }

    func testCancelledRestoreKeepsBookmarkAndHoldsScopeUntilMetadataDrains() async throws {
        for isStale in [false, true] {
            let harness = AccessHarness()
            let bookmark = seed(harness, isStale: isStale)
            harness.files.parkMetadata = true
            let restore = Task { try await harness.service.restore(bookmark: bookmark, scope: .directory) }
            await waitUntil { harness.files.parkedMetadataCount == 1 }
            restore.cancel()
            do {
                _ = try await restore.value
                XCTFail("cancelled restore issued a grant")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            assertRetryable(harness, bookmark: bookmark)
            XCTAssertEqual(harness.scope.endCount, 0)
            harness.files.resumeMetadata()
            await waitUntil { harness.scope.endCount == 1 }
            XCTAssertEqual(harness.bookmarks.bookmarkCallCount, 0)
            harness.files.parkMetadata = false
            let grant = try await harness.service.restore(bookmark: bookmark, scope: .directory)
            _ = harness.service.invalidate(grant.workspaceID)
            XCTAssertEqual(harness.scope.endCount, 2)
        }
    }

    func testRestoreDeadlineKeepsBookmarkAndRejectsLateMetadata() async throws {
        let harness = AccessHarness(coordinationTimeoutNanoseconds: 50_000_000)
        let bookmark = seed(harness, isStale: true)
        harness.files.parkMetadata = true
        let restore = Task { try await harness.service.restore(bookmark: bookmark, scope: .directory) }
        await waitUntil { harness.files.parkedMetadataCount == 1 }
        do {
            _ = try await restore.value
            XCTFail("deadline issued a grant")
        } catch {
            XCTAssertEqual(error as? IOSWorkspaceFailure, .coordinationFailed)
        }
        assertRetryable(harness, bookmark: bookmark)
        XCTAssertEqual(harness.scope.endCount, 0)
        harness.files.resumeMetadata()
        await waitUntil { harness.scope.endCount == 1 }
        XCTAssertTrue(harness.service.records.isEmpty)
        XCTAssertEqual(harness.bookmarks.bookmarkCallCount, 0)
    }

    func testTransientStaleMintFailureKeepsTheOldBytesAvailable() async throws {
        let harness = AccessHarness()
        let bookmark = seed(harness, isStale: true)
        harness.bookmarks.onBookmark = { throw IOSWorkspaceFailure.coordinationFailed }
        do {
            _ = try await harness.service.restore(bookmark: bookmark, scope: .directory)
            XCTFail("failed mint issued a grant")
        } catch {
            XCTAssertEqual(error as? IOSWorkspaceFailure, .coordinationFailed)
        }
        assertRetryable(harness, bookmark: bookmark)
        XCTAssertEqual(harness.scope.endCount, 1)
        harness.bookmarks.onBookmark = nil
        let grant = try await harness.service.restore(bookmark: bookmark, scope: .directory)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.bookmark, harness.bookmarks.refreshed)
        _ = harness.service.invalidate(grant.workspaceID)
        XCTAssertEqual(harness.scope.endCount, 2)
    }

    private func seed(_ harness: AccessHarness, isStale: Bool) -> Data {
        let bookmark = Data("retryable-bookmark".utf8)
        harness.bookmarks.resolution = .resolved(
            IOSWorkspacePathAuthority.fileURL(path: "/tmp/retry/Folder"), isStale: isStale
        )
        harness.recents.save([IOSStoredRecentWorkspace(
            recordID: UUID(), displayName: "Folder", scope: .directory,
            openedAt: Date(timeIntervalSince1970: 0), providerIdentity: nil,
            status: .available, bookmark: bookmark
        )])
        return bookmark
    }

    private func assertRetryable(_ harness: AccessHarness, bookmark: Data) {
        XCTAssertTrue(harness.service.records.isEmpty)
        XCTAssertEqual(harness.recents.load().count, 1)
        XCTAssertEqual(harness.recents.load().first?.bookmark, bookmark)
        XCTAssertEqual(harness.recents.load().first?.status, .available)
    }
}
