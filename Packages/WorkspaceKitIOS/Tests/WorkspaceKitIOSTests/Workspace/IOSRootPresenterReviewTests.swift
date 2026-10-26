import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSRootPresenterReviewTests: XCTestCase {
    func testEvictionKeepsThePresenterAndLaterRootChangesRefreshTheDirectory() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        let record = try XCTUnwrap(harness.service.records[grant.workspaceID])
        let service = harness.service
        let presenter = IOSRootFilePresenter(root: grant.rootURL) { notice in
            Task { @MainActor in
                service.ingest(IOSQueuedWorkspaceNotice(
                    workspaceID: grant.workspaceID, generation: grant.accessGeneration,
                    rootToken: record.rootToken, notice: notice
                ))
            }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        var events: [IOSWorkspaceEvent] = []
        _ = service.observe { events.append($0) }
        presenter.accommodatePresentedItemEviction { XCTAssertNil($0) }
        XCTAssertTrue(NSFileCoordinator.filePresenters.contains { $0 === presenter })
        await waitUntil { events.contains { event in
            if case let .unavailable(identity, .offline) = event {
                return identity == grant.workspaceID
            }
            return false
        } }
        presenter.presentedItemDidChange()
        await waitUntil { service.snapshot(for: grant.workspaceID) != nil }
        XCTAssertEqual(harness.files.listCalls, 1)
        XCTAssertFalse(events.contains { event in
            if case .resourceChanged = event {
                return true
            }
            return false
        }, "a directory root callback must not invent Folder/Folder")
    }

    func testUnprovedRootMoveRevokesTheOldGrantWithoutInventingAChild() async throws {
        let watcher = ScriptedWorkspaceWatcher()
        let harness = AccessHarness(watcher: watcher)
        let grant = try await harness.openDirectory()
        let lease = try harness.service.acquireLease(for: grant)
        var events: [IOSWorkspaceEvent] = []
        _ = harness.service.observe { events.append($0) }
        watcher.emit(.rootMoved, identity: grant.workspaceID)
        await waitUntil { harness.service.records[grant.workspaceID]?.revoked == true }
        XCTAssertThrowsError(try harness.service.acquireLease(for: grant))
        XCTAssertFalse(lease.isReleased)
        XCTAssertEqual(harness.scope.endCount, 0, "existing consumers must drain before scope stop")
        XCTAssertEqual(harness.service.records[grant.workspaceID]?.rootURL, grant.rootURL)
        XCTAssertEqual(harness.service.recentItems().first?.status, .needsReselection)
        XCTAssertFalse(events.contains { event in
            if case .resourceChanged = event {
                return true
            }
            return false
        })
        lease.release()
        XCTAssertEqual(harness.scope.endCount, 1)
    }

    func testRootDeletionRevokesTheGrant() async throws {
        let watcher = ScriptedWorkspaceWatcher()
        let harness = AccessHarness(watcher: watcher)
        let grant = try await harness.openFile()
        watcher.emit(.rootDeleted, identity: grant.workspaceID)
        await waitUntil { harness.service.currentGrant(for: grant.workspaceID) == nil }
        XCTAssertEqual(harness.scope.endCount, 1)
    }

    func testSingleFileRootChangeReportsTheGrantedFile() async throws {
        let watcher = ScriptedWorkspaceWatcher()
        let harness = AccessHarness(watcher: watcher)
        let grant = try await harness.openFile()
        var locations: [IOSFileLocation] = []
        _ = harness.service.observe { event in
            if case let .resourceChanged(location) = event {
                locations.append(location)
            }
        }
        watcher.emit(.rootChanged, identity: grant.workspaceID)
        await waitUntil { locations.count == 1 }
        XCTAssertEqual(locations.first?.fileURL, grant.rootURL)
        XCTAssertEqual(locations.first?.relativePath, "Note.md")
    }
}
