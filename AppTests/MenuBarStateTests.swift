import Combine
import Foundation
@testable import Plainsong
import XCTest

@MainActor
final class MenuBarStateTests: XCTestCase {
    func testInitialSnapshotMirrorsAppState() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        let menuState = MenuBarState(appState: appState)

        XCTAssertEqual(menuState.snapshot.hasOpenDocument, appState.hasOpenDocument)
        XCTAssertEqual(menuState.snapshot.canSave, appState.canSave)
        XCTAssertEqual(
            menuState.snapshot.canUseWorkspaceSearch,
            appState.canUseWorkspaceSearch
        )
        XCTAssertEqual(
            menuState.snapshot.layoutModeCommandTitle,
            appState.layoutModeCommandTitle
        )
        XCTAssertEqual(menuState.snapshot.recentItemURLs, appState.recentItemURLs)
    }

    /// A menu-relevant mutation must republish exactly once, and only after the mutation
    /// has landed (`objectWillChange` fires pre-mutation; a menu rebuilt at that instant
    /// would re-read stale values — the launch-time frozen-disabled bug).
    func testMenuRelevantChangePublishesPostMutationExactlyOnce() async throws {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        let menuState = MenuBarState(appState: appState)
        var published: [MenuBarSnapshot] = []
        let subscription = menuState.$snapshot.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }

        XCTAssertFalse(menuState.snapshot.canUseWorkspaceSearch)

        appState.workspaceRootURL = URL(fileURLWithPath: "/tmp/menu-bar-state-tests")
        // Synchronously after the mutation the snapshot is still the old one — the
        // republish is scheduled for the next main run-loop pass.
        XCTAssertFalse(menuState.snapshot.canUseWorkspaceSearch)

        try await waitUntilMenuState("workspace-open snapshot publishes") {
            published.count == 1
        }
        XCTAssertEqual(published.last?.canUseWorkspaceSearch, true)
        XCTAssertTrue(menuState.snapshot.canUseWorkspaceSearch)

        appState.workspaceRootURL = nil
        try await waitUntilMenuState("workspace-close snapshot publishes") {
            published.count == 2
        }
        XCTAssertEqual(published.last?.canUseWorkspaceSearch, false)
    }

    /// High-frequency publishes that do not change any menu fact must not rebuild the
    /// menu: the snapshot publisher stays silent while `objectWillChange` churns.
    func testMenuIrrelevantChurnDoesNotRepublish() async throws {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        let menuState = MenuBarState(appState: appState)
        var publishedCount = 0
        let subscription = menuState.$snapshot.dropFirst().sink { _ in publishedCount += 1 }
        defer { subscription.cancel() }

        var willChangeCount = 0
        let churnProbe = appState.objectWillChange.sink { _ in willChangeCount += 1 }
        defer { churnProbe.cancel() }

        // Search chrome churn (no folder workspace → search stays cleared) publishes
        // through AppState but never changes a menu fact.
        appState.updateWorkspaceSearchQueryText("a")
        appState.updateWorkspaceSearchQueryText("ab")
        appState.updateWorkspaceSearchQueryText("abc")
        appState.updateWorkspaceSearchQueryText("")

        try await settleMainQueue()
        XCTAssertGreaterThan(willChangeCount, 0, "test must exercise real churn")
        XCTAssertEqual(publishedCount, 0, "menu-irrelevant churn must not rebuild the menu")
    }

    // MARK: - Helpers

    private func settleMainQueue() async throws {
        for _ in 0 ..< 5 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func waitUntilMenuState(
        _ description: String,
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }
}
