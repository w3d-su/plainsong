import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSRootNoticeCoalescingTests: XCTestCase {
    func testRootMoveRevokesAccessWithCollidingChildInEitherOrder() async throws {
        try await assertRootRevocation(.rootMoved, childPath: "root-moved", needsReselection: true)
    }

    func testRootDeletionRevokesAccessWithCollidingChildInEitherOrder() async throws {
        try await assertRootRevocation(.rootDeleted, childPath: "root-deleted", needsReselection: false)
    }

    func testRootChangeAndCollidingChildBothPublishInEitherOrder() async throws {
        for rootFirst in [true, false] {
            let harness = AccessHarness()
            let grant = try await harness.openDirectory()
            let record = try XCTUnwrap(harness.service.records[grant.workspaceID])
            var paths: [String] = []
            _ = harness.service.observe { event in
                if case let .resourceChanged(location) = event {
                    paths.append(location.relativePath)
                }
            }
            ingestPair(.rootChanged, childPath: "root-changed", rootFirst: rootFirst, record: record, harness: harness)
            harness.service.flushNotices()
            await waitUntil { harness.service.snapshot(for: grant.workspaceID) != nil }
            XCTAssertEqual(paths, ["root-changed"])
            XCTAssertEqual(harness.files.listCalls, 1)
            XCTAssertFalse(record.revoked)
            _ = harness.service.invalidate(grant.workspaceID)
        }
    }

    func testOfflineRootAndCollidingChildBothPublishInEitherOrder() async throws {
        for rootFirst in [true, false] {
            let harness = AccessHarness()
            let grant = try await harness.openDirectory()
            let record = try XCTUnwrap(harness.service.records[grant.workspaceID])
            var paths: [String] = []
            var unavailable: [IOSWorkspaceFailure] = []
            _ = harness.service.observe { event in
                if case let .resourceChanged(location) = event {
                    paths.append(location.relativePath)
                }
                if case let .unavailable(_, reason) = event {
                    unavailable.append(reason)
                }
            }
            ingestPair(.offlineRoot, childPath: "offline", rootFirst: rootFirst, record: record, harness: harness)
            harness.service.flushNotices()
            XCTAssertEqual(paths, ["offline"])
            XCTAssertEqual(unavailable, [.offline])
            XCTAssertFalse(record.revoked)
            _ = harness.service.invalidate(grant.workspaceID)
        }
    }

    func testChildNoticesCoalesceBySourcePathAndKeepDistinctByteSpellings() async throws {
        let harness = AccessHarness()
        let grant = try await harness.openDirectory()
        let record = try XCTUnwrap(harness.service.records[grant.workspaceID])
        var paths: [WorkspacePathByteKey] = []
        _ = harness.service.observe { event in
            if case let .resourceChanged(location) = event {
                paths.append(WorkspacePathByteKey(location.relativePath))
            }
        }
        let source = "root-moved"
        let composed = "caf\u{e9}.md"
        let decomposed = "cafe\u{301}.md"
        let notices: [IOSExternalWorkspaceNotice] = [
            .changed(relativePath: source), .deleted(relativePath: source),
            .availability(relativePath: source, .offline), .moved(from: source, to: "destination.md"),
            .changed(relativePath: composed), .changed(relativePath: decomposed),
        ]
        for notice in notices {
            harness.service.ingest(queued(notice, record: record))
        }
        harness.service.flushNotices()
        XCTAssertEqual(
            paths.sorted(),
            [source, "destination.md", composed, decomposed].map(WorkspacePathByteKey.init).sorted()
        )
        XCTAssertFalse(record.revoked)
        _ = harness.service.invalidate(grant.workspaceID)
    }

    func testStaleNoticeBoundariesCannotSuppressCurrentRootRevocation() async throws {
        for staleLast in [true, false] {
            let harness = AccessHarness()
            let grant = try await harness.openDirectory()
            let record = try XCTUnwrap(harness.service.records[grant.workspaceID])
            let current = queued(.rootMoved, record: record)
            var oldGeneration = current
            oldGeneration.generation &-= 1
            var oldRoot = current
            oldRoot.rootToken = UUID()
            var otherWorkspace = current
            otherWorkspace.workspaceID = IOSWorkspaceIdentity(rawValue: UUID())
            let stale = [oldGeneration, oldRoot, otherWorkspace]
            for notice in staleLast ? [current] + stale : stale + [current] {
                harness.service.ingest(notice)
            }
            harness.service.flushNotices()
            XCTAssertTrue(record.revoked)
            XCTAssertThrowsError(try harness.service.acquireLease(for: grant))
            XCTAssertEqual(harness.service.recentItems().first?.status, .needsReselection)
            XCTAssertEqual(harness.scope.endCount, 1)
        }
    }

    private func assertRootRevocation(
        _ root: IOSExternalWorkspaceNotice,
        childPath: String,
        needsReselection: Bool
    ) async throws {
        for rootFirst in [true, false] {
            let harness = AccessHarness()
            let grant = try await harness.openDirectory()
            let record = try XCTUnwrap(harness.service.records[grant.workspaceID])
            let lease = try harness.service.acquireLease(for: grant)
            var invalidations = 0
            _ = harness.service.observe { event in
                if case .invalidated = event {
                    invalidations += 1
                }
            }
            ingestPair(root, childPath: childPath, rootFirst: rootFirst, record: record, harness: harness)
            harness.service.flushNotices()
            XCTAssertTrue(record.revoked)
            XCTAssertEqual(invalidations, 1)
            XCTAssertThrowsError(try harness.service.acquireLease(for: grant))
            if needsReselection {
                XCTAssertEqual(harness.service.recentItems().first?.status, .needsReselection)
            }
            XCTAssertEqual(harness.scope.endCount, 0, "a root notice must preserve the lease's drain hold")
            lease.release()
            XCTAssertEqual(harness.scope.endCount, 1)
        }
    }

    private func ingestPair(
        _ root: IOSExternalWorkspaceNotice,
        childPath: String,
        rootFirst: Bool,
        record: IOSWorkspaceScopeRecord,
        harness: AccessHarness
    ) {
        XCTAssertNotNil(WorkspaceRelativePath(spelling: childPath))
        let child = IOSExternalWorkspaceNotice.changed(relativePath: childPath)
        for notice in rootFirst ? [root, child] : [child, root] {
            harness.service.ingest(queued(notice, record: record))
        }
    }

    private func queued(_ notice: IOSExternalWorkspaceNotice,
                        record: IOSWorkspaceScopeRecord) -> IOSQueuedWorkspaceNotice
    {
        IOSQueuedWorkspaceNotice(
            workspaceID: record.workspaceID, generation: record.generation, rootToken: record.rootToken, notice: notice
        )
    }
}
