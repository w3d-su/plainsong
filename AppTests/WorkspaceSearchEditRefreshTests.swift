import MarkdownCore
@testable import Plainsong
import WorkspaceKit
import XCTest

/// Edit-driven search refresh waits for a typing pause and for the Search navigator
/// (`docs/decisions/2026-10-22-edit-driven-search-refresh-waits-for-a-pause.md`).
@MainActor
final class WorkspaceSearchEditRefreshTests: XCTestCase {
    func testEditsDoNotRestartTheSearchUntilTheyPause() async throws {
        let provider = ActiveSearchRefreshProvider()
        let fixture = try makeActiveSearchRefreshFixture(
            provider: provider,
            scanner: ActiveSearchRefreshScanner(),
            files: ["a.md": "saved"],
            currentPath: "a.md"
        )
        defer { cleanUpActiveSearchRefreshFixture(fixture) }
        let appState = fixture.appState
        appState.workspaceSearchEditRefresh.delayNanoseconds = 150_000_000
        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "needle"))
        try await waitForActiveSearchRefresh("initial search") { provider.requests.count == 1 }
        let generation = appState.workspaceSearchState.queryGeneration

        appState.applyAuthorizedEditorText("needle one", to: appState.currentDocument)
        appState.applyAuthorizedEditorText("needle two", to: appState.currentDocument)

        // Typing neither replaces the search state (a whole-window publish) nor restarts it.
        XCTAssertEqual(appState.workspaceSearchState.queryGeneration, generation)
        XCTAssertEqual(appState.workspaceSearchState.activeQuery?.pattern, "needle")
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(provider.requests.count, 1)

        try await waitForActiveSearchRefresh("one refresh after the pause") { provider.requests.count == 2 }
        XCTAssertEqual(provider.requests[1].dirtyOverlays.overlays.first?.text, "needle two")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(provider.requests.count, 2)
    }

    func testEditsWhileFilesShowsRefreshWhenSearchShowsAgain() async throws {
        let provider = ActiveSearchRefreshProvider()
        let fixture = try makeActiveSearchRefreshFixture(
            provider: provider,
            scanner: ActiveSearchRefreshScanner(),
            files: ["a.md": "saved"],
            currentPath: "a.md"
        )
        defer { cleanUpActiveSearchRefreshFixture(fixture) }
        let appState = fixture.appState
        appState.setWorkspaceSearchQuery(TextSearchQuery(pattern: "needle"))
        try await waitForActiveSearchRefresh("initial search") { provider.requests.count == 1 }

        appState.selectWorkspaceSidebarMode(.files)
        appState.applyAuthorizedEditorText("needle hidden", to: appState.currentDocument)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(provider.requests.count, 1, "no search runs while Files is showing")
        XCTAssertTrue(appState.workspaceSearchEditRefresh.isPendingUntilSearchShows)

        appState.selectWorkspaceSidebarMode(.search)
        try await waitForActiveSearchRefresh("refresh when Search shows") { provider.requests.count == 2 }
        XCTAssertEqual(provider.requests[1].dirtyOverlays.overlays.first?.text, "needle hidden")
        XCTAssertFalse(appState.workspaceSearchEditRefresh.isPendingUntilSearchShows)
    }

    func testFileResultsStaySortedAndReplaceTheSamePath() {
        let appState = AppState(shouldRestoreLastOpenedFile: false)
        let paths = ["b/z.md", "a.md", "c.md", "b/a.md", "Z.md", "é.md", "a.md"]
        for (index, path) in paths.enumerated() {
            appState.applyWorkspaceSearchFileResult(WorkspaceSearchFileResult(
                relativePath: path,
                contentFingerprint: WorkspaceSearchContentFingerprint(text: "\(index)"),
                matches: [],
                isTruncated: false,
                fileAuthority: nil
            ))
        }

        let stored = appState.workspaceSearchState.fileResults
        XCTAssertEqual(stored.map(\.relativePath), ["Z.md", "a.md", "b/a.md", "b/z.md", "c.md", "é.md"])
        XCTAssertEqual(
            stored.first { $0.relativePath == "a.md" }?.contentFingerprint,
            WorkspaceSearchContentFingerprint(text: "6"),
            "a later result for the same path replaces the earlier one"
        )
    }
}
