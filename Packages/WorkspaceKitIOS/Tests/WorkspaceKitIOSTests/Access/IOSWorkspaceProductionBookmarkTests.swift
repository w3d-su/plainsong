import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSWorkspaceProductionBookmarkTests: XCTestCase {
    func testLocalBookmarkRoundTripLeavesProviderIdentityUnknown() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainsong-lane06-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.md")
        try Data("hello".utf8).write(to: file)
        let bookmarks = IOSSystemBookmarkPort()
        let bookmark: Data
        do {
            bookmark = try bookmarks.bookmark(for: file)
        } catch {
            throw XCTSkip("simulator bookmark creation failed: \(error)")
        }
        let resolved = try bookmarks.resolve(bookmark)
        guard resolved.failure == nil, resolved.url != nil else {
            throw XCTSkip("simulator bookmark resolution failed: \(String(describing: resolved.failure))")
        }
        let service = IOSWorkspaceAccessService(
            ports: IOSWorkspaceAccessPorts(
                scope: IOSSystemSecurityScopePort(),
                bookmarks: bookmarks,
                identity: IOSSystemProviderIdentityPort(),
                files: IOSSystemWorkspaceFilePort(),
                recents: ScriptedRecentStore(),
                watcher: IOSIdleWorkspaceWatcher(),
                clock: { Date(timeIntervalSince1970: 1_700_000_000) },
                coordinationTimeoutNanoseconds: 5_000_000_000
            )
        )
        let grant = try await service.restore(bookmark: bookmark, scope: .singleFile)
        XCTAssertNil(service.records[grant.workspaceID]?.providerIdentity)
        let lease = try service.acquireLease(for: grant)
        let read = try await service.read(
            IOSFileLocation(
                workspaceID: grant.workspaceID,
                accessGeneration: grant.accessGeneration,
                relativePath: "Note.md",
                fileURL: grant.rootURL,
                resourceID: nil
            ),
            lease: lease,
            operationID: UUID(),
            maximumByteCount: 64
        )
        XCTAssertEqual(read.data, Data("hello".utf8))
        lease.release()
        _ = service.invalidate(grant.workspaceID)
    }
}
