import Foundation
import WorkspaceCore
@testable import WorkspaceKitIOS
import XCTest

@MainActor
final class IOSWorkspaceNoticeRoutingTests: XCTestCase {
    func testTwoRootsDoNotShareARelativePathNotice() async throws {
        let watcher = ScriptedWorkspaceWatcher()
        let harness = AccessHarness(watcher: watcher)
        let first = try await harness.openDirectory("/tmp/plainsong-lane06/RootA")
        let second = try await harness.openDirectory("/tmp/plainsong-lane06/RootB")
        var seen: [IOSWorkspaceEvent] = []
        _ = harness.service.observe { seen.append($0) }
        watcher.emit(.changed(relativePath: "Note.md"), identity: first.workspaceID)
        watcher.emit(.changed(relativePath: "Note.md"), identity: second.workspaceID)
        await waitUntil { self.workspaceIDs(in: seen).count >= 2 }
        XCTAssertEqual(workspaceIDs(in: seen).filter { $0 == first.workspaceID }.count, 1)
        XCTAssertEqual(workspaceIDs(in: seen).filter { $0 == second.workspaceID }.count, 1)
    }

    func testOfflineNoticeStaysOnTheOriginatingRoot() async throws {
        let watcher = ScriptedWorkspaceWatcher()
        let harness = AccessHarness(watcher: watcher)
        let first = try await harness.openDirectory("/tmp/plainsong-lane06/OfflineA")
        let second = try await harness.openDirectory("/tmp/plainsong-lane06/OfflineB")
        var seen: [IOSWorkspaceEvent] = []
        _ = harness.service.observe { seen.append($0) }
        watcher.emit(.offlineRoot, identity: first.workspaceID)
        await waitUntil { seen.contains { self.isOffline($0, workspaceID: first.workspaceID) } }
        XCTAssertTrue(seen.contains { isOffline($0, workspaceID: first.workspaceID) })
        XCTAssertFalse(seen.contains { isOffline($0, workspaceID: second.workspaceID) })
        XCTAssertFalse(workspaceIDs(in: seen).contains(second.workspaceID))
    }

    func testLateNoticeAfterInvalidateDoesNotReachANewRoot() async throws {
        let watcher = ScriptedWorkspaceWatcher()
        let harness = AccessHarness(watcher: watcher)
        let original = try await harness.openDirectory("/tmp/plainsong-lane06/LateA")
        let sink = try XCTUnwrap(watcher.sink(for: original.workspaceID))
        var seen: [IOSWorkspaceEvent] = []
        _ = harness.service.observe { seen.append($0) }
        _ = harness.service.invalidate(original.workspaceID)
        let replacement = try await harness.openDirectory("/tmp/plainsong-lane06/LateB")
        let before = seen.count
        sink(.changed(relativePath: "Note.md"))
        sink(.offlineRoot)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(seen.count, before)
        XCTAssertFalse(workspaceIDs(in: seen).contains(replacement.workspaceID))
        XCTAssertFalse(seen.contains { isOffline($0, workspaceID: replacement.workspaceID) })
        XCTAssertFalse(seen.contains { isOffline($0, workspaceID: original.workspaceID) })
    }

    private func workspaceIDs(in events: [IOSWorkspaceEvent]) -> [IOSWorkspaceIdentity] {
        events.compactMap { event in
            if case let .resourceChanged(location) = event {
                return location.workspaceID
            }
            return nil
        }
    }

    private func isOffline(_ event: IOSWorkspaceEvent, workspaceID: IOSWorkspaceIdentity) -> Bool {
        if case let .unavailable(identity, reason) = event {
            return identity == workspaceID && reason == .offline
        }
        return false
    }
}
