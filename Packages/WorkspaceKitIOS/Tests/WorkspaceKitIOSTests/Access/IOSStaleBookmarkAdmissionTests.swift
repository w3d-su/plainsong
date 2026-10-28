import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSStaleBookmarkAdmissionTests: XCTestCase {
    func testStaleRefreshMintsOnlyInsideTheAdmittedScope() async throws {
        let harness = AccessHarness()
        let stale = seedStale(harness)
        let scope = harness.scope
        harness.bookmarks.onBookmark = {
            guard scope.beganURLs.count == 1, scope.endCount == 0 else {
                throw IOSWorkspaceFailure.permissionDenied
            }
        }
        let grant = try await harness.service.restore(bookmark: stale, scope: .directory)
        XCTAssertEqual(harness.bookmarks.bookmarkCallCount, 1)
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.bookmark, harness.bookmarks.refreshed)
        XCTAssertFalse(harness.recents.load().contains { $0.bookmark == stale })
        XCTAssertEqual(scope.endCount, 0)
        _ = harness.service.invalidate(grant.workspaceID)
        XCTAssertEqual(scope.endCount, 1)
    }

    func testDeniedStaleRestoreDoesNotMintOrReplaceTheBookmark() async {
        let harness = AccessHarness()
        let stale = seedStale(harness)
        harness.scope.admission = .denied
        await assertRestoreRefused(harness, bookmark: stale)
        XCTAssertEqual(harness.bookmarks.bookmarkCallCount, 0)
        XCTAssertEqual(harness.scope.endCount, 0)
    }

    func testMintFailureStopsOnlyTheScopeThisRestoreStarted() async {
        for admission in [IOSScopeAdmission.started, .reachableWithoutNewScope] {
            let harness = AccessHarness()
            let stale = seedStale(harness)
            harness.scope.admission = admission
            harness.bookmarks.onBookmark = { throw IOSWorkspaceFailure.permissionDenied }
            await assertRestoreRefused(harness, bookmark: stale)
            XCTAssertEqual(harness.scope.endCount, admission == .started ? 1 : 0)
        }
    }

    private func seedStale(_ harness: AccessHarness) -> Data {
        let stale = Data("old-bookmark".utf8)
        harness.bookmarks.resolution = .resolved(
            IOSWorkspacePathAuthority.fileURL(path: "/tmp/stale/Folder"), isStale: true
        )
        harness.recents.save([IOSStoredRecentWorkspace(
            recordID: UUID(), displayName: "Folder", scope: .directory,
            openedAt: Date(timeIntervalSince1970: 0), providerIdentity: nil,
            status: .available, bookmark: stale
        )])
        return stale
    }

    private func assertRestoreRefused(_ harness: AccessHarness, bookmark: Data) async {
        do {
            _ = try await harness.service.restore(bookmark: bookmark, scope: .directory)
            XCTFail("restore must refuse a failed admission or refresh")
        } catch {
            XCTAssertEqual(error as? IOSWorkspaceFailure, .permissionDenied)
        }
        XCTAssertTrue(harness.service.records.isEmpty)
        XCTAssertEqual(harness.recents.load().count, 1)
        XCTAssertEqual(harness.recents.load().first?.bookmark, bookmark)
        XCTAssertEqual(harness.recents.load().first?.status, .needsReselection)
    }
}
