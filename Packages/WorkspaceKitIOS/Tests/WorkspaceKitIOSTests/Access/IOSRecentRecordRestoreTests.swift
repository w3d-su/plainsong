import Foundation
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSRecentRecordRestoreTests: XCTestCase {
    func testRecordIDRestoresStoredScopeWithoutUsingDisplayNameAsAURL() async throws {
        let harness = AccessHarness()
        let item = stored(scope: .directory, name: "../untrusted display name.md")
        harness.recents.save([item])
        let url = URL(fileURLWithPath: "/tmp/plainsong-lane06/Folder")
        harness.files.rootIsDirectory = true
        harness.bookmarks.resolution = .resolved(url, isStale: false)

        let grant = try await harness.service.restoreRecent(recordID: item.recordID)

        XCTAssertEqual(grant.rootURL, url)
        XCTAssertEqual(grant.scope, .directory)
        XCTAssertEqual(harness.service.recentItems().map(\.recordID), [item.recordID])
        XCTAssertEqual(harness.service.recentItems().first?.status, .available)
        XCTAssertEqual(harness.scope.beganURLs, [url])
    }

    func testStaleBookmarkRefreshPreservesTheRecordIDAndFreshMetadata() async throws {
        let harness = AccessHarness()
        let item = stored(scope: .singleFile)
        harness.recents.save([item])
        let url = URL(fileURLWithPath: "/tmp/plainsong-lane06/Folder/Note.md")
        harness.files.rootIsDirectory = false
        harness.bookmarks.resolution = .resolved(url, isStale: true)

        let grant = try await harness.service.restoreRecent(recordID: item.recordID)

        XCTAssertEqual(grant.scope, .singleFile)
        let records = harness.recents.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.recordID, item.recordID)
        XCTAssertEqual(records.first?.bookmark, harness.bookmarks.refreshed)
        XCTAssertEqual(records.first?.displayName, "Note.md")
        XCTAssertEqual(records.first?.status, .available)
    }

    func testRemovedRecordCannotRestoreAndRemoveDoesNotTouchFiles() async throws {
        let harness = AccessHarness()
        let item = stored(scope: .singleFile)
        harness.recents.save([item])
        let ioBefore = harness.files.ioCalls
        harness.service.removeRecent(recordID: item.recordID)
        do {
            _ = try await harness.service.restoreRecent(recordID: item.recordID)
            XCTFail("An absent record must not become a grant")
        } catch {
            XCTAssertEqual(error as? IOSWorkspaceFailure, .notFound)
        }
        XCTAssertEqual(harness.files.ioCalls, ioBefore)
        XCTAssertTrue(harness.scope.beganURLs.isEmpty)
        XCTAssertTrue(harness.service.recentItems().isEmpty)
    }

    func testDeniedRecordNeedsReselectionWhileOfflineRecordKeepsItsMetadata() async throws {
        let harness = AccessHarness()
        let item = stored(scope: .directory)
        let url = URL(fileURLWithPath: "/tmp/plainsong-lane06/Folder")
        harness.recents.save([item])
        harness.bookmarks.resolution = IOSBookmarkResolution(url: url, isStale: false, failure: .permissionDenied)
        do {
            _ = try await harness.service.restoreRecent(recordID: item.recordID)
            XCTFail("Denied bookmark must not become a grant")
        } catch {
            XCTAssertEqual(error as? IOSWorkspaceFailure, .permissionDenied)
        }
        XCTAssertEqual(harness.service.recentItems().first?.status, .needsReselection)
        harness.recents.save([item])
        harness.bookmarks.resolution = IOSBookmarkResolution(url: url, isStale: false, failure: .offline)
        do {
            _ = try await harness.service.restoreRecent(recordID: item.recordID)
            XCTFail("Offline bookmark must not become a grant")
        } catch {
            XCTAssertEqual(error as? IOSWorkspaceFailure, .offline)
        }
        XCTAssertEqual(harness.recents.load(), [item])
        harness.scope.admission = .denied
        harness.bookmarks.resolution = .resolved(url, isStale: false)
        do {
            _ = try await harness.service.restoreRecent(recordID: item.recordID)
            XCTFail("Scope admission denial must also mark the record")
        } catch {
            XCTAssertEqual(error as? IOSWorkspaceFailure, .permissionDenied)
        }
        XCTAssertEqual(harness.service.recentItems().first?.status, .needsReselection)
    }

    func testRemoveDuringParkedRestoreCannotResurrectMetadataOrReturnAGrant() async throws {
        let harness = AccessHarness()
        let item = stored(scope: .directory)
        harness.recents.save([item])
        harness.files.rootIsDirectory = true
        harness.files.parkMetadata = true
        harness.bookmarks.resolution = .resolved(URL(fileURLWithPath: "/tmp/plainsong-lane06/Folder"), isStale: false)
        let restore = Task { @MainActor in try await harness.service.restoreRecent(recordID: item.recordID) }
        await waitUntil { harness.files.parkedMetadataCount == 1 }
        guard harness.files.parkedMetadataCount == 1 else {
            restore.cancel()
            throw IOSWorkspaceFailure.unavailable
        }
        harness.service.removeRecent(recordID: item.recordID)
        harness.files.parkMetadata = false
        harness.files.resumeMetadata()
        do {
            _ = try await restore.value
            XCTFail("Removed issuance cannot return its late grant")
        } catch {
            XCTAssertEqual(error as? IOSWorkspaceFailure, .notFound)
        }
        XCTAssertTrue(harness.recents.load().isEmpty)
        XCTAssertTrue(harness.service.records.values.allSatisfy { $0.revoked && $0.stopped })
        XCTAssertEqual(harness.files.createCalls, 0)
        XCTAssertTrue(harness.files.removeURLs.isEmpty)
    }

    func testDuplicateRestoreIsRefusedBeforeASecondScopeAndCancellationDoesNotAddARecord() async throws {
        let harness = AccessHarness()
        let item = stored(scope: .directory)
        harness.recents.save([item])
        harness.files.rootIsDirectory = true
        harness.files.parkMetadata = true
        harness.bookmarks.resolution = .resolved(URL(fileURLWithPath: "/tmp/plainsong-lane06/Folder"), isStale: false)
        let restore = Task { @MainActor in try await harness.service.restoreRecent(recordID: item.recordID) }
        await waitUntil { harness.files.parkedMetadataCount == 1 }
        guard harness.files.parkedMetadataCount == 1 else {
            restore.cancel()
            throw IOSWorkspaceFailure.unavailable
        }
        do {
            _ = try await harness.service.restoreRecent(recordID: item.recordID)
            XCTFail("The same record already has a parked restore")
        } catch {
            XCTAssertEqual(error as? IOSWorkspaceFailure, .unavailable)
        }
        XCTAssertEqual(harness.scope.beganURLs.count, 1)
        restore.cancel()
        harness.files.parkMetadata = false
        harness.files.resumeMetadata()
        do {
            _ = try await restore.value
            XCTFail("Cancelled restore must not return a grant")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(harness.service.recentItems().map(\.recordID), [item.recordID])
        XCTAssertTrue(harness.files.removeURLs.isEmpty)
    }

    private func stored(scope: IOSWorkspaceScope, name: String = "Note.md") -> IOSStoredRecentWorkspace {
        IOSStoredRecentWorkspace(recordID: UUID(), displayName: name, scope: scope,
                                 openedAt: Date(timeIntervalSince1970: 10), providerIdentity: nil, status: .available,
                                 bookmark: Data("controlled-bookmark".utf8))
    }
}
